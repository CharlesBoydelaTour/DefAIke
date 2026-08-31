import DefAIkeDomain
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeSharedTransfer
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 15.2: the scaffolding for the final application-composition tests.
//
// ## Why this file exists, and what it is not
//
// Task 15.2's eight subjects are already covered, thoroughly, by five earlier suites:
//
//   * **12.4** drives both real ingest routes through the real coordinator to a real
//     `AnalysisScreen`, across three compositions, five post-ingest faults, and a
//     cancellation at every suspension.
//   * **10.13** covers every error stage, branch ordering, retry, termination boundary,
//     cleanup reason, resource breach, cancellation point, and late callback.
//   * **11.8** value-snapshots every reducer output.
//   * **11.9** projects the accessibility layer over 74 screens.
//   * **12.5** audits offline behaviour over the two release archives.
//
// Repeating any of that would add test count and no evidence. The span none of them can
// reach is the one this file is about: **the composition roots' own graphs**.
//
// ## The blocker, stated exactly
//
// `MainAppComposition`, `AdmittedMainApp`, `MainAppStartupOutcome`, `IngestAttemptRecord`,
// `UnpresentableTerminalOutcome`, `MainAppReleaseProvisioning`, `UnprovisionedReleaseInput`,
// `ShareExtensionComposition`, `AdmittedShareExtension`, `ReadyHandoffReceipt`, and
// `AdmittedHandoffOutcome` all live in `ios/DefAIkeApp/` and
// `ios/DefAIkeShareExtension/`. Those directories are compiled by the Xcode project alone
// and belong to no SwiftPM target, so **no test in this package can import them**, and
// `project.yml` declares no app-target unit-test target to put such a test in. The two
// device-validation bundles that do exist are deliberately un-hosted logic bundles
// (`TEST_HOST = ""`), because both compositions build the same `DefAIke.app` and any real
// `TEST_HOST` path makes Xcode's implicit-dependency resolution fail with
// `Multiple commands produce .../DefAIke.app`. Hosting them would require the two
// compositions to build distinct product names, which is a release-visible change.
//
// So this file does the two things that *are* possible, and says plainly what neither of
// them reaches:
//
//   1. **A composition-faithful graph.** ``CompositionGraph`` assembles
//      `AnalysisCoordinator`, both ingest coordinators, terminal cleanup, and the provenance
//      lane with *exactly the argument shape* `MainAppComposition.assemble(...)` passes —
//      including the three arguments no earlier harness uses: a `nil` fuser derived from
//      `OptionalFusion.omitted(.noRuleBound)`, a `nil` provenance analyzer derived from
//      `CapabilityComposition.provenanceAnalyzer(...)`, and a `ProtectedSessionDataDeleter`
//      over the session store *only*.
//   2. **A source-text correspondence audit.** ``CompositionRootSourceAudit`` reads the two
//      composition-root files as authored and pins each wiring decision the graph above
//      reproduces. That is what makes the reproduction checkable rather than asserted: if
//      the composition root stops passing `fuser: fusion.approvedRule`, the audit fails even
//      though the graph still compiles.
//
// **What remains uncovered, and cannot be covered from here:** the composition root's own
// control flow — its step ordering, its ten `MainAppStartupRefusal` cases, its eleven-gap
// `unprovisionedInputs(bundle:)` report, `AdmittedMainApp`'s private initializer, and the
// `UnpresentableTerminalOutcome` record — is unreachable. Every claim below is about a
// collaborator the composition root calls, or about its source text, never about the
// function itself.
//
// ## What is real here, and what is substituted
//
// Real, and new to this file:
//
//   * **`ProtectedEphemeralFileStore`, on the host file system.** Every earlier
//     cross-module suite uses `InMemoryEphemeralStore`. The composition root's graph is built
//     on the protected store, its `SessionStorageNamespace` conformance, and
//     `ProtectedSessionDataDeleter` over it — so those are what run here, with real scope
//     directories, real capacity enforcement from the bound budget, and real deletion
//     receipts.
//   * The real `PhotosImportAdapter`, `PhotosIngestCoordinator`, `SharedTransferStore`,
//     `ShareExtensionIngestCoordinator`, `ShareHandoffClaimAdapter`,
//     `ShareHandoffIngestCoordinator`, `AnalysisSessionBinder`, `AnalysisCoordinator`,
//     `SessionTerminalCleanup`, `ProvenanceLaneProvider`, `ApprovedCopyBinding`,
//     `AnalysisScreen`, `EvidenceReportPresentation`, and
//     `AccessibilitySemanticsSnapshot`.
//   * **No scripted session identity and no reduced chunk size.** The composition root passes
//     neither, so neither is passed here: session identifiers come from the shipping
//     `PhotosIngestCoordinator` default source and from the extension's own candidate source,
//     and both adapters stream at their shipping default chunk size.
//
// Substituted, with the reason:
//
//   * **Data protection is not applied to host files.** ``HostRecordingDataProtection``
//     creates the real directories and files and *records* the level the store asked for
//     instead of setting the attribute. This is the seam `DataProtectionApplying` exists for,
//     and it exists to avoid the known intermittent host condition where a directory accepts
//     `NSFileProtectionComplete` and then refuses file creation inside it with `EPERM`.
//     **No production fail-closed path is weakened**: the applier still throws where the
//     store expects a throw, the store still fails closed, and the level the composition root
//     reads from the signed Extension Execution Policy — `.complete` in this fixture — is
//     what is requested and asserted. **No result in this file is Requirement 9.6 evidence**;
//     `PlatformDataProtection.enforcesDataProtection` is `false` off iOS regardless, and this
//     applier reports `false` for the same reason.
//   * **Validation, preprocessing, model loading, inference, and calibration** are the shared
//     stubs. The real Image I/O and Core ML paths belong to their own targets.
//   * **The storage roots are temporary directories.** The composition root resolves them
//     through `SessionStorageRoots.appPrivateRoot()` and
//     `AppGroupContainer.transferRoot(forAppGroup:)`; both resolvers are exercised directly
//     in their own arm rather than by writing into the host's real application-support tree.
//   * **The cleanup policy has five distinct deadlines.**
//     `CoordinatorSample.lifecyclePolicy()` gives all five reasons the same duration, which
//     makes every "this reason's deadline" assertion vacuous. `IntegrationLifecycle`'s
//     distinct policy is substituted for `configuration.lifecyclePolicy`, exactly as
//     `MatrixHarness` does, and it carries the same artifact identifier.
//   * **A provenance analyzer, where one is needed.** There is no shipping
//     `ProvenanceAnalyzing` conformance at all: `C2PAProvenanceValidator` deliberately does
//     not conform, so `CapabilityComposition.provenanceAnalyzer(...)` returns `nil` in *both*
//     shipping compositions and `c2pa-swift` 0.0.12 refuses configuration with synthetic
//     anchors. The shipping arms therefore pass `nil`, and the arms that need an available
//     lane use a fixture analyzer and say so.
//
// ## Nothing here is an approved release value
//
// Every identifier, byte sequence, deadline, capacity, protection level, and copy key is
// synthetic scaffolding. No number below may be copied into a shipping artifact, and no host
// result here is physical-device evidence.

// MARK: - Locating the composition roots

/// One composition-root source file, addressed relative to the repository checkout.
///
/// A closed vocabulary rather than a path string per assertion, so a file that moved fails
/// once with its own name instead of failing every arm that mentions it.
enum CompositionRootFile: String, Sendable, CaseIterable, CustomStringConvertible {
    case mainAppComposition = "DefAIkeApp/Shared/MainAppComposition.swift"
    case mainAppScene = "DefAIkeApp/Shared/MainAppScene.swift"
    case mainAppPlatform = "DefAIkeApp/Shared/MainAppPlatform.swift"
    case mainAppReleaseProvisioning = "DefAIkeApp/Shared/MainAppReleaseProvisioning.swift"
    case capabilityComposition = "DefAIkeApp/Shared/CapabilityComposition.swift"
    case shareExtensionComposition =
        "DefAIkeShareExtension/Sources/ShareExtensionComposition.swift"

    var description: String { rawValue }

    /// The file's own name, for a finding that has to be readable.
    var fileName: String {
        String(rawValue.split(separator: "/").last ?? "")
    }
}

/// Reads the app-target and extension-target sources this package cannot import.
///
/// The `ios/` directory is the parent of the package root, which is found by walking up from
/// this file to the directory holding `Package.swift`. That makes the location independent of
/// whichever working directory a runner chose.
///
/// When the walk fails, the arms fail. A missing source tree means the question was not
/// answered, and a skipped correspondence check is indistinguishable from a passing one.
enum CompositionRootSourceAudit {

    /// Failures this audit reports rather than force-unwrapping.
    enum Failure: Error, CustomStringConvertible {
        case checkoutNotFound
        case fileNotReadable(CompositionRootFile)

        var description: String {
            switch self {
            case .checkoutNotFound:
                return "the ios/ checkout could not be located from this test file"
            case let .fileNotReadable(file):
                return "the composition-root source \(file.rawValue) could not be read"
            }
        }
    }

    /// The `ios/` directory, or `nil` when this file is not inside the checkout.
    static let checkoutRoot: URL? = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) {
                // `directory` is `ios/DefAIkePackage`; the app and extension targets are its
                // siblings under `ios/`.
                return directory.deletingLastPathComponent()
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// The source of one composition-root file, exactly as authored.
    static func source(of file: CompositionRootFile) throws -> String {
        guard let checkoutRoot else { throw Failure.checkoutNotFound }
        let url = checkoutRoot.appending(path: file.rawValue)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.fileNotReadable(file)
        }
        return text
    }

    /// The source of one composition-root file with `//` comment text removed.
    ///
    /// Stripping is mandatory rather than tidy. These files document what they refuse to do,
    /// in prose, using the same words a naive sweep searches for: unstripped, the
    /// network-surface sweep below reports three findings, all of them sentences explaining
    /// that there is no download and no remote catalogue. An audit a doc comment can fail is
    /// an audit that gets weakened rather than obeyed.
    ///
    /// No source in either target puts `//` inside a string literal, and every token searched
    /// for is one that would never appear in one, so a line-wise split is enough.
    static func strippedSource(of file: CompositionRootFile) throws -> String {
        strippingComments(try source(of: file))
    }

    /// Removes `//` comment text.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    // MARK: The network-surface sweep

    /// Framework entry points any network access from a composition root would need.
    ///
    /// Absence of all of them is what "the composition root reaches no network" means at the
    /// source level. It is *not* a claim about the linked archives: the provenance
    /// composition statically links a Rust HTTP/2 and TLS stack through `c2pa-swift`, and its
    /// offline guarantee is runtime configuration rather than absence. See
    /// ``CompositionOfflineSurfaceTests`` for that distinction stated in full.
    static let networkTokens = [
        "URLSession",
        "URLRequest",
        "NSURLConnection",
        "NWConnection",
        "CFNetwork",
        "http://",
        "https://",
        "download",
        "remote",
        "upload",
        "telemetry",
    ]

    /// One token found in one file.
    struct Finding: Hashable, CustomStringConvertible {
        let file: String
        let token: String

        var description: String { "\(file) mentions \(token)" }
    }

    /// Every network token in the comment-stripped sources of `files`.
    static func networkFindings(
        in files: [CompositionRootFile]
    ) throws -> [Finding] {
        var found: [Finding] = []
        for file in files {
            let code = try strippedSource(of: file)
            for token in networkTokens where code.contains(token) {
                found.append(Finding(file: file.fileName, token: token))
            }
        }
        return found
    }

    /// Every network token in the sources of `files` *without* stripping comments.
    ///
    /// Exists so the arm that establishes "stripping is load-bearing" can compare the two
    /// counts rather than assert that stripping matters in a comment.
    static func unstrippedNetworkFindings(
        in files: [CompositionRootFile]
    ) throws -> [Finding] {
        var found: [Finding] = []
        for file in files {
            let code = try source(of: file)
            for token in networkTokens where code.contains(token) {
                found.append(Finding(file: file.fileName, token: token))
            }
        }
        return found
    }
}

// MARK: - The pinned wiring decisions

/// One argument the composition root passes that ``CompositionGraph`` reproduces.
///
/// Each case names a decision, the file it is made in, and the exact comment-stripped text
/// that makes it. The point is correspondence: every behavioural claim in this file about
/// what the shipping graph does rests on the composition root really passing these, and this
/// vocabulary is what turns that from a comment into a failing test.
///
/// No case here is a style rule. Each one changes a user-visible outcome — whether a Combined
/// Summary can ever appear, whether a validator is ever invoked, which storage the terminal
/// cleanup owns, whether the evidence branches can run concurrently.
enum CompositionWiringDecision: String, Sendable, CaseIterable, CustomStringConvertible {

    /// The main app resolves a provisioned candidate with its bound fixture suite.
    case fusionResolvesFromProvisionedFixtures

    /// The coordinator's fusion port comes from the resolved optional fusion.
    case fuserComesFromResolvedFusion

    /// No apparent-inconsistency classifier is installed.
    case noInconsistencyClassifier

    /// Evidence branches run serially, under the admitted validation plan.
    case serialBranchExecutionUnderTheBoundPlan

    /// Terminal cleanup owns the session store and nothing else.
    case terminalCleanupOwnsTheSessionStoreOnly

    /// Terminal cleanup is audited against the admitted lifecycle policy.
    case terminalCleanupBindsTheAdmittedPolicy

    /// The provenance lane is resolved from the composition's own analyzer factory.
    case provenanceLaneResolvedFromTheCompositionAnalyzer

    /// The staged-file protection level comes from the signed Extension Execution Policy.
    case protectionLevelComesFromTheExtensionPolicy

    /// Session-store capacity comes from the bound budget through the store's own factory.
    case storeCapacityComesFromTheBoundBudget

    /// The startup sweep stores are capacity-zero, so the gate cannot retain a byte.
    case startupSweepStoresHaveZeroCapacity

    /// The Calibration Policy is activated for the admitted bundle against the evidence index.
    case calibrationPolicyActivatedForTheAdmittedBundle

    /// The Resource Controller is bound to this target's budget through a target-checked init.
    case resourceControllerBoundToThisTarget

    /// Approved wording is resolved through the shipped catalog, or startup refuses.
    case approvedCopyResolvedFromTheShippedCatalog

    /// The extension's protection level comes from its admission.
    case extensionProtectionLevelComesFromTheAdmission

    /// Every published ticket is stamped with the observed build identity.
    case extensionTicketsStampTheObservedBuild

    /// The extension's ingest coordinator is bound to the extension's own budget.
    case extensionIngestBoundToTheExtensionBudget

    var description: String { rawValue }

    /// The file this decision is made in.
    var file: CompositionRootFile {
        switch self {
        case .extensionProtectionLevelComesFromTheAdmission,
            .extensionTicketsStampTheObservedBuild,
            .extensionIngestBoundToTheExtensionBudget:
            .shareExtensionComposition
        default:
            .mainAppComposition
        }
    }

    /// The comment-stripped text that makes this decision.
    var pinnedText: String {
        switch self {
        case .fusionResolvesFromProvisionedFixtures:
            "if let fixtures = provisioning.fusionFixtures"
        case .fuserComesFromResolvedFusion:
            "fuser: fusion.approvedRule"
        case .noInconsistencyClassifier:
            "inconsistencyClassifier: nil"
        case .serialBranchExecutionUnderTheBoundPlan:
            "validationPlan: admission.boundValidationPlan"
        case .terminalCleanupOwnsTheSessionStoreOnly:
            "deleter: ProtectedSessionDataDeleter(namespaces: [sessionStore]),"
        case .terminalCleanupBindsTheAdmittedPolicy:
            "policy: configuration.lifecyclePolicy"
        case .provenanceLaneResolvedFromTheCompositionAnalyzer:
            "analyzer: composition.provenanceAnalyzer("
        case .protectionLevelComesFromTheExtensionPolicy:
            "let protectionLevel = configuration.extensionExecutionPolicy.stagedFileProtection"
        case .storeCapacityComesFromTheBoundBudget:
            "ProtectedEphemeralFileStore.configuration("
        case .startupSweepStoresHaveZeroCapacity:
            "capacityInBytes: 0,"
        case .calibrationPolicyActivatedForTheAdmittedBundle:
            "ValidatedCalibrationPolicy("
        case .resourceControllerBoundToThisTarget:
            "ResourceController("
        case .approvedCopyResolvedFromTheShippedCatalog:
            "AccessibleTextResolver.shipped()"
        case .extensionProtectionLevelComesFromTheAdmission:
            "let protectionLevel = admission.stagedFileProtection"
        case .extensionTicketsStampTheObservedBuild:
            "buildID: admission.device.appBuild,"
        case .extensionIngestBoundToTheExtensionBudget:
            "budget: admission.budget,"
        }
    }

    /// A second fragment that must accompany the first, or `nil` when one suffices.
    ///
    /// Present where a bare fragment would be satisfied by a call that made the opposite
    /// decision: `ApprovedEvidenceBranchExecution(...)` names the type, and `execution:
    /// .serial` is the decision.
    var accompanyingText: String? {
        switch self {
        case .fusionResolvesFromProvisionedFixtures:
            "fusion = .resolving("
        case .serialBranchExecutionUnderTheBoundPlan:
            "execution: .serial,"
        case .startupSweepStoresHaveZeroCapacity:
            "containerProtection: .complete"
        case .provenanceLaneResolvedFromTheCompositionAnalyzer:
            "ProvenanceLaneProvider.resolve("
        case .storeCapacityComesFromTheBoundBudget:
            "budget: budget,"
        case .calibrationPolicyActivatedForTheAdmittedBundle:
            "for: admission.bundle.manifest,"
        case .resourceControllerBoundToThisTarget:
            "governor: PlatformResourceGovernor(target: target)"
        default:
            nil
        }
    }
}

// MARK: - Host data protection, recorded rather than applied

/// Creates the real directories and files a protected store needs and records the level it
/// asked for, without setting the platform attribute.
///
/// **This does not weaken a fail-closed path.** `ProtectedEphemeralFileStore` fails closed
/// whenever this applier throws, and it throws for exactly the conditions
/// `PlatformDataProtection` throws for: a directory it cannot create, and a file that already
/// exists. What it does not do is set `NSFileProtectionComplete`, because a host directory
/// created with that attribute intermittently refuses file creation inside it with `EPERM` —
/// in `/var/folders`, in `/tmp`, and under `$HOME` alike. Avoiding the attribute is what lets
/// the *rest* of the shipping store run for real here.
///
/// ``enforcesDataProtection`` is `false`, which is the truth and is also what
/// `PlatformDataProtection` reports off iOS. **No result obtained through this applier is
/// Requirement 9.6 evidence.**
final class HostRecordingDataProtection: DataProtectionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [String: FileProtectionLevel] = [:]

    var enforcesDataProtection: Bool { false }

    /// Every level this store asked for, deduplicated.
    ///
    /// The composition root reads one level from the signed Extension Execution Policy and
    /// passes it everywhere, so a run that requested two different levels is a wiring fault.
    var requestedLevels: Set<FileProtectionLevel> {
        lock.withLock { Set(requested.values) }
    }

    /// How many items were created through this applier.
    var createdItemCount: Int { lock.withLock { requested.count } }

    private func note(_ url: URL, _ level: FileProtectionLevel) {
        lock.withLock { requested[url.path] = level }
    }

    func createProtectedDirectory(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            note(url, level)
            return
        }
        guard
            (try? manager.createDirectory(at: url, withIntermediateDirectories: true)) != nil
        else {
            throw .storeUnavailable
        }
        note(url, level)
    }

    func createProtectedFile(
        at url: URL,
        level: FileProtectionLevel
    ) throws(EphemeralStoreError) {
        let manager = FileManager.default
        // The same refusal `PlatformDataProtection` makes: overwriting would discard bytes an
        // existing handle may still describe.
        guard !manager.fileExists(atPath: url.path) else { throw .storeUnavailable }
        guard manager.createFile(atPath: url.path, contents: nil, attributes: nil) else {
            throw .storeUnavailable
        }
        note(url, level)
        return
    }

    func appliedLevel(ofItemAt url: URL) -> FileProtectionLevel? {
        lock.withLock { requested[url.path] }
    }
}

// MARK: - Pipeline stubs that stamp the session they were given

// The shared `StubInputValidator` and `StubImagePreprocessor` answer with one value programmed
// before the run, which means one *pre-chosen* session identifier. That works when a harness
// scripts the identifier, and it cannot work here: the composition root passes no identity
// source to `PhotosIngestCoordinator` and mints the Share candidate inside the extension, so
// the session identifier is not known until the ingest has already happened. A pre-stamped
// value then reaches a coordinator that checks it, and every session fails at input validation
// with `decoding-error` — which is the real behaviour for a stage that answered about a
// different session, and is not the behaviour under test.
//
// These two doubles stamp the session and the bound contract they were handed, which is what
// the real Image I/O validator and preprocessor do. Faults stay programmable, so the failed
// terminal is still reachable.

/// An `InputValidating` double that answers about the session it was asked about.
final class CompositionInputValidator: InputValidating, Sendable {
    private let fault: AnalysisFault?
    private let recorder: PortCallRecorder

    init(recorder: PortCallRecorder, failingWith fault: AnalysisFault? = nil) {
        self.recorder = recorder
        self.fault = fault
    }

    func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage {
        recorder.record(.validate(asset.sessionID))
        if let fault { throw fault }
        return PortValue.validatedImage(
            sessionID: asset.sessionID,
            preprocessingContractID: contract.id
        )
    }
}

/// An `ImagePreprocessing` double that answers about the session it was asked about.
final class CompositionImagePreprocessor: ImagePreprocessing, Sendable {
    private let fault: AnalysisFault?
    private let recorder: PortCallRecorder

    init(recorder: PortCallRecorder, failingWith fault: AnalysisFault? = nil) {
        self.recorder = recorder
        self.fault = fault
    }

    func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        recorder.record(.preprocess(image.sessionID))
        if let fault { throw fault }
        return PortValue.modelInput(
            sessionID: image.sessionID,
            preprocessingContractID: contract.id
        )
    }
}

// MARK: - Whether this composition has an analyzer to supply

/// What `CapabilityComposition.provenanceAnalyzer(store:policy:)` returns for a build.
///
/// Two cases, and the shipping one is `absent` in *both* release compositions. That is not a
/// simplification: `DefAIkeProvenanceC2PA`'s `C2PAProvenanceValidator` deliberately does not
/// conform to `ProvenanceAnalyzing`, so the pixel-plus-provenance build links a validator it
/// cannot pass to the lane. ``fixture`` exists so the enabled-lane plumbing can still be
/// driven, and every arm using it says the real path is unreachable.
enum CompositionAnalyzerPresence: String, Sendable, CaseIterable, CustomStringConvertible {
    /// What both shipping compositions supply today.
    case absent

    /// A conforming analyzer, which no shipping module provides.
    case fixture

    var description: String { rawValue }
}

// MARK: - The composition-faithful graph

/// Failures this file's helpers report, so no helper force-unwraps.
enum CompositionGraphFailure: Error, CustomStringConvertible {
    case noAcceptedIngest
    case noPublishedHandoff
    case noResumedSession
    case noSessionRan
    case noReport
    case noScreen
    case storeUnconfigurable
    case resourceControllerUnbindable
    case extensionIngestUnbindable
    case hostDirectoryUnavailable

    var description: String { "composition-graph setup failed: \(String(describing: self))" }
}

/// One coherent synthetic release, assembled the way `MainAppComposition.assemble(...)`
/// assembles it.
///
/// Every argument below either matches the composition root's exactly, or is a substitution
/// documented in this file's header. The four that no earlier harness passes are the point:
///
///   * `fuser: fusion.approvedRule` where `fusion` is `.omitted(.noRuleBound)` — so the
///     coordinator has no fusion port at all, in *every* composition including the
///     fusion-enabled one.
///   * `provenance: ProvenanceLaneProvider.resolve(analyzer: nil, ...)` — so the lane is
///     unavailable in every composition, including the provenance-enabled one, which is what
///     the shipping composition does today.
///   * `cleanup:` over a real `ProtectedSessionDataDeleter` holding the session store alone.
///   * `branchExecution:` serial under the admitted validation plan.
struct CompositionGraph {
    let release: CoordinatorRelease
    let composition: FlowComposition
    let analyzerPresence: CompositionAnalyzerPresence

    /// The level the signed Extension Execution Policy names, and the only level requested.
    let protectionLevel: FileProtectionLevel

    /// The app-private session store, and the only namespace terminal cleanup owns.
    let sessionStore: ProtectedEphemeralFileStore

    /// The App Group transfer store, which terminal cleanup deliberately does not own.
    let transferStore: ProtectedEphemeralFileStore

    /// The applier both stores create through.
    let protection: HostRecordingDataProtection

    /// The real deleter the composition root builds, over the session store alone.
    let deleter: ProtectedSessionDataDeleter

    /// The lifecycle policy terminal cleanup is audited against.
    let policy: DataLifecyclePolicy

    let provenance: ProvenanceLaneProvider
    let fusion: OptionalFusion
    let coordinator: AnalysisCoordinator
    let binder: AnalysisSessionBinder
    let recorder: PortCallRecorder
    let transfers: SharedTransferStore
    let resources: ResourceController

    /// A second binder over the same admission and active bundle, for copy resolution.
    ///
    /// The coordinator releases its binding on the single end path, so a terminal outcome
    /// carries no `AnalysisSessionBinding` for a screen to resolve copy through. Binding the
    /// same accepted ingest through an independent binder reproduces the value.
    let presentationBinder: AnalysisSessionBinder

    /// Directories to remove when the arm is done.
    let hostRoots: [URL]

    /// The gate armed at the inference suspension, for the cancellation arms.
    let gate: BranchGate

    var configuration: ReleaseConfiguration { release.admission.configuration }
    var context: ReleaseContext { release.admission.context }

    // MARK: Construction

    static func make(
        _ composition: FlowComposition = .pixelOnly,
        analyzer analyzerPresence: CompositionAnalyzerPresence = .absent,
        validationFault: AnalysisFault? = nil,
        preprocessingFault: AnalysisFault? = nil,
        model: StubOutcome<BoundCoreMLModel>? = nil,
        logit: StubOutcome<RawLogit>? = nil,
        evidence: StubOutcome<PixelEvidence>? = nil,
        provenanceState: ProvenanceEvidence = .absent,
        gateInference: Bool = false
    ) async throws -> CompositionGraph {
        let release = try await CoordinatorRelease.build(
            provenance: composition.enablesProvenance,
            fusion: composition.enablesFusion
        )
        let configuration = release.admission.configuration

        // Step: the protection level, from the signed Extension Execution Policy. The
        // composition root reads exactly this member and passes it to every store and both
        // ingest adapters.
        let protectionLevel = configuration.extensionExecutionPolicy.stagedFileProtection
        let protection = HostRecordingDataProtection()

        // Step: capacity from the bound budget, through the store's own factory. The roots
        // are temporary directories rather than the resolved application containers; the
        // resolvers themselves are exercised in their own arm.
        let budget = configuration.resourceBudgets.budget(for: .mainApplication)
        guard let sessionRoot = Self.makeHostRoot("sessions"),
            let transferRoot = Self.makeHostRoot("transfers")
        else {
            throw CompositionGraphFailure.hostDirectoryUnavailable
        }
        let sessionConfiguration: ProtectedEphemeralFileStore.Configuration
        let transferConfiguration: ProtectedEphemeralFileStore.Configuration
        do {
            sessionConfiguration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: sessionRoot,
                budget: budget,
                containerProtection: protectionLevel
            )
            transferConfiguration = try ProtectedEphemeralFileStore.configuration(
                rootDirectory: transferRoot,
                budget: budget,
                containerProtection: protectionLevel
            )
        } catch {
            throw CompositionGraphFailure.storeUnconfigurable
        }
        let sessionStore = ProtectedEphemeralFileStore(
            configuration: sessionConfiguration,
            protection: protection,
            clock: release.clock
        )
        let transferStore = ProtectedEphemeralFileStore(
            configuration: transferConfiguration,
            protection: protection,
            clock: release.clock
        )

        guard let resources = ResourceController(
            target: .mainApplication,
            budgets: configuration.resourceBudgets,
            governor: FakeResourceGovernor(target: .mainApplication)
        ) else {
            throw CompositionGraphFailure.resourceControllerUnbindable
        }

        // Step: the conditional provenance lane, resolved from whatever the composition's own
        // analyzer factory supplies. `absent` is what the shipping composition supplies.
        let recorder = release.recorder
        let analyzer: (any ProvenanceAnalyzing)? =
            switch analyzerPresence {
            case .absent: nil
            case .fixture: StubProvenanceAnalyzer(always: provenanceState, recorder: recorder)
            }
        let provenance = ProvenanceLaneProvider.resolve(
            // Paired with the manifest the way the startup gate requires: preflight refuses a
            // build whose `linksContentCredentialValidator` disagrees with the manifest's
            // `enablesProvenance`, so a coherent synthetic release cannot vary them apart.
            linksValidator: composition.enablesProvenance,
            analyzer: analyzer,
            policy: configuration.provenancePolicy,
            manifest: configuration.capabilityManifest
        )

        // Step: the optional Combined Summary. The composition root hard-codes this, so a
        // fusion-enabled manifest still reaches the coordinator with no fusion port.
        let fusion: OptionalFusion = .omitted(.noRuleBound)

        // Substituted for `configuration.lifecyclePolicy`: five distinct deadlines under the
        // same artifact identifier, so a reason-to-deadline assertion is not vacuous.
        let policy = IntegrationLifecycle.distinctPolicy()
        let deleter = ProtectedSessionDataDeleter(
            namespaces: [sessionStore],
            clock: release.clock
        )

        let gate = BranchGate()
        let binder = release.binder()
        let coordinator = AnalysisCoordinator(
            binder: binder,
            validator: CompositionInputValidator(
                recorder: recorder,
                failingWith: validationFault
            ),
            preprocessor: CompositionImagePreprocessor(
                recorder: recorder,
                failingWith: preprocessingFault
            ),
            modelLoader: StubPixelModelLoader(
                outcome: model
                    ?? StubOutcome(always: CoordinatorSample.loadedModel(bundle: release.bundle)),
                recorder: recorder
            ),
            analyzer: GatedPixelAnalyzer(
                outcome: logit ?? StubOutcome(always: PortValue.logit(1.5)),
                recorder: recorder,
                gate: gateInference ? gate : nil
            ),
            calibrator: StubPixelCalibrator(
                outcome: evidence ?? StubOutcome(always: .signalsConsistentWithAIGeneration),
                recorder: recorder
            ),
            provenance: provenance,
            fuser: fusion.approvedRule,
            inconsistencyClassifier: nil,
            cleanup: SessionTerminalCleanup(deleter: deleter, policy: policy),
            branchExecution: ApprovedEvidenceBranchExecution(
                execution: .serial,
                validationPlan: release.admission.boundValidationPlan
            )
        )

        let transfers = SharedTransferStore(
            store: transferStore,
            lifecyclePolicy: configuration.lifecyclePolicy,
            extensionPolicy: configuration.extensionExecutionPolicy,
            buildID: release.admission.context.device.appBuild,
            clock: release.clock
        )

        let presentationBundles = StubModelBundleManager()
        await presentationBundles.installAndActivate(release.bundle)

        return CompositionGraph(
            release: release,
            composition: composition,
            analyzerPresence: analyzerPresence,
            protectionLevel: protectionLevel,
            sessionStore: sessionStore,
            transferStore: transferStore,
            protection: protection,
            deleter: deleter,
            policy: policy,
            provenance: provenance,
            fusion: fusion,
            coordinator: coordinator,
            binder: binder,
            recorder: recorder,
            transfers: transfers,
            resources: resources,
            presentationBinder: AnalysisSessionBinder(
                admission: release.admission,
                bundles: presentationBundles
            ),
            hostRoots: [sessionRoot, transferRoot],
            gate: gate
        )
    }

    /// A fresh temporary directory, or `nil` when the host refused.
    ///
    /// No protection attribute is applied to it. That is deliberate: the store creates its
    /// own root, scope, and object directories through the injected applier, and applying an
    /// attribute here would reach for the one host behaviour this file is built to avoid.
    static func makeHostRoot(_ label: String) -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(
                path: "defaike-t152-\(label)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        guard
            (try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )) != nil
        else { return nil }
        return directory
    }

    /// Removes every host directory this graph created.
    ///
    /// Retried, because the store creates its root lazily: a scope directory prepared by an
    /// actor that has just finished can reappear under a root this call already emptied, and a
    /// single `removeItem` then fails with a nonempty directory. Under a loaded parallel run
    /// that was observed to leave a handful of *empty* directories behind — no bytes, but temp
    /// litter — so the removal is attempted more than once rather than assumed to succeed.
    func removeHostRoots() {
        let manager = FileManager.default
        for root in hostRoots {
            for _ in 0..<5 {
                guard manager.fileExists(atPath: root.path) else { break }
                try? manager.removeItem(at: root)
            }
        }
    }

    // MARK: Ingest, the composition root's way

    /// One real Photos ingest attempt, through the adapter the composition root builds.
    ///
    /// No scripted identity and no reduced chunk size, because the composition root passes
    /// neither: the session identifier comes from the shipping default source and the copy
    /// streams at the shipping default chunk size.
    func ingestPhotos(
        bytes: [UInt8] = CompositionSample.payload(),
        form: SuppliedRepresentationForm = .typedFileRepresentation,
        itemCount: Int = 1,
        providerFault: PhotosProviderFault? = nil,
        provider: FlowPhotosProvider? = nil
    ) async -> PhotosIngestOutcome {
        let access = provider
            ?? FlowPhotosProvider(bytes: bytes, form: form, failingWith: providerFault)
        let ingest = PhotosIngestCoordinator(
            importer: PhotosImportAdapter(
                access: access,
                store: sessionStore,
                sessionFileProtection: protectionLevel
            )
        )
        return await ingest.ingest(Fixture.selection(itemCount: itemCount))
    }

    /// One real extension activation: consent, protected staging, atomic publication.
    func publishShareHandoff(
        bytes: [UInt8] = CompositionSample.payload(),
        consent: FlowConsentPresenter.Answer = .confirm,
        itemCount: Int = 1
    ) async throws -> ShareHandoffOutcome {
        guard let extensionIngest = ShareExtensionIngestCoordinator(
            access: FlowSharedItemProvider(bytes: bytes),
            consentPresenter: FlowConsentPresenter(consent),
            transfers: transfers,
            governor: FakeResourceGovernor(target: .shareExtension),
            budget: configuration.resourceBudgets.shareExtension,
            instruction: CompositionSample.openInstruction
        ) else {
            throw CompositionGraphFailure.extensionIngestUnbindable
        }
        guard let provider = SharedItemProvider(
            token: ProviderToken(rawValue: 1),
            itemCount: itemCount,
            contentTypeHint: Fixture.contentTypeHint()
        ) else {
            throw CompositionGraphFailure.extensionIngestUnbindable
        }
        return await extensionIngest.handleActivation(
            ShareActivation(providers: [provider])
        )
    }

    /// The main app's real claim, through the adapter the composition root builds.
    func claimShareHandoff() async -> ShareHandoffIngestOutcome {
        let ingest = ShareHandoffIngestCoordinator(
            claiming: ShareHandoffClaimAdapter(
                transfers: transfers,
                sessionStore: sessionStore,
                sessionFileProtection: protectionLevel
            ),
            bundles: release.bundles
        )
        return await ingest.resumePendingHandoff(context: context)
    }

    /// The accepted ingest one route produces.
    func acceptedIngest(
        _ route: FlowRoute,
        bytes: [UInt8] = CompositionSample.payload()
    ) async throws -> ImportedEncodedAsset {
        switch route {
        case .photos:
            guard let asset = await ingestPhotos(bytes: bytes).acceptedIngest else {
                throw CompositionGraphFailure.noAcceptedIngest
            }
            return asset
        case .claimedShare:
            guard case .published = try await publishShareHandoff(bytes: bytes) else {
                throw CompositionGraphFailure.noPublishedHandoff
            }
            guard let resumed = await claimShareHandoff().resumedSession else {
                throw CompositionGraphFailure.noResumedSession
            }
            return resumed.asset
        }
    }

    /// Ingests through `route` and runs the session to its single terminal outcome.
    func run(
        _ route: FlowRoute,
        bytes: [UInt8] = CompositionSample.payload()
    ) async throws -> CompositionRun {
        let asset = try await acceptedIngest(route, bytes: bytes)
        guard let session = await coordinator.analyze(asset).completed else {
            throw CompositionGraphFailure.noSessionRan
        }
        return CompositionRun(asset: asset, session: session)
    }

    // MARK: Presentation

    /// Approved copy bound to one session, through a superset catalogue.
    ///
    /// `FlowCopy`'s superset rather than the release's own catalogue, for the reason task 12.4
    /// recorded: a fusion-enabled release's registered catalogue cannot bind its own Combined
    /// Summary keys. The binding is released again immediately, so a retry that reuses the
    /// identifier stays bindable.
    func copyBinding(for asset: ImportedEncodedAsset) async throws -> ApprovedCopyBinding {
        let bound = try await presentationBinder.bind(accepting: asset)
        await presentationBinder.release(asset.sessionID)
        return try ApprovedCopyBinding.bind(
            catalog: FlowCopy.catalog(
                capabilities: configuration.capabilityManifest,
                fusionRule: configuration.fusionRule
            ),
            session: bound.binding,
            capabilities: configuration.capabilityManifest,
            fusionRule: configuration.fusionRule
        )
    }

    /// The screen one terminal outcome projects to.
    func screen(
        for session: CompletedAnalysisSession,
        copy: ApprovedCopyBinding
    ) throws -> AnalysisScreen {
        try AnalysisScreen.projecting(
            .session(
                AnalysisSessionSnapshot(
                    identity: SessionAttemptIdentity(
                        sessionID: session.sessionID,
                        attemptGeneration: session.identity.generation
                    ),
                    phase: .ended(session.outcome),
                    copy: copy
                )
            )
        )
    }

    // MARK: Inspection

    /// Objects the app-private session store still holds for one session.
    func sessionObjectCount(_ sessionID: AnalysisSessionID) async -> Int {
        await sessionStore.keys(in: .session(sessionID)).count
    }

    /// Every scope the App Group transfer store still holds an object in.
    func occupiedTransferScopes() async -> Set<EphemeralStorageScope> {
        await transferStore.occupiedScopes()
    }
}

// MARK: - One run, with both ends kept

/// One completed session and the accepted ingest it ran over.
struct CompositionRun: Sendable {
    let asset: ImportedEncodedAsset
    let session: CompletedAnalysisSession

    var sessionID: AnalysisSessionID { asset.sessionID }
    var outcome: SessionTerminalOutcome { session.outcome }
}

// MARK: - The terminal a graph is driven to

/// Which terminal outcome an arm drives the session to.
///
/// Three cases, because `SessionTerminalOutcome` has three. The fourth terminal an audit
/// might look for — a `handoff-error` failure committed before Model Bundle binding — is
/// deliberately absent from this axis: Requirement 2.19 requires it *before* binding, so the
/// session holds no `AnalysisSessionBinding`, `ApprovedCopyBinding.bind` needs one, and the
/// terminal is irreducibly unpresentable. The composition root records that as
/// `UnpresentableTerminalOutcome.handoffErrorBeforeBundleBinding`, task 12.4 pins that
/// neither binder binds a session for it, and nothing here can improve on either.
enum CompositionTerminal: String, Sendable, CaseIterable, CustomStringConvertible {
    case completed
    case cancelled
    case failed

    var description: String { rawValue }
}

// MARK: - Synthetic scalars

/// The synthetic values this file needs as arguments.
///
/// **No value here is an approved release value.**
enum CompositionSample {
    /// A deterministic payload, reproducible so a failure can be replayed.
    static func payload(count: Int = 256, seed: UInt8 = 7) -> [UInt8] {
        PortValue.bytes(count: count, seed: seed)
    }

    /// The "Open DefAIke" instruction, as an approved copy key rather than a sentence.
    static let openInstruction = ManualOpenInstruction(
        copyKey: CoordinatorSample.copyKey("copy.surface.share.manual-open-instruction")
    )

    /// An evidence index resolving exactly what the fixture Calibration Policy cites.
    static func evidenceIndex() throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: [CoordinatorSample.evidence("evidence.calibration")]
        )
    }

    /// An evidence index resolving something else, so activation refuses.
    ///
    /// The `calibrationPolicyNotActivatable` branch of the composition root's startup: a
    /// policy citing evidence this release does not carry keeps the bundle unusable rather
    /// than producing a user-facing verdict.
    static func mismatchedEvidenceIndex() throws -> ReleaseEvidenceIndex {
        try ReleaseEvidenceIndex(
            records: [CoordinatorSample.evidence("evidence.something-else")]
        )
    }

    /// A schema-legal budget whose temporary-storage ceiling truncates to zero bytes.
    ///
    /// `ResourceLimitEntry` requires a numeric limit for a non-categorical metric, so "no
    /// numeric limit at all" is not a representable budget. A sub-byte ceiling is, and it
    /// reaches the same refusal: the store truncates rather than rounds, because a ceiling is
    /// a limit and the enforced value must never exceed the approved one — so half a byte
    /// becomes zero and `ProtectedEphemeralFileStore.configuration` throws
    /// `temporaryStorageLimitUnavailable`. That is the composition root's
    /// `sessionStoreNotConfigurable` refusal.
    static func budgetWithUnusableTemporaryStorage() -> ResourceBudget {
        // Half a byte. Positive, so the schema accepts it; below one, so no whole byte of
        // approved capacity exists to enforce.
        let subByte = Decimal(sign: .plus, exponent: -1, significand: 5)
        do {
            return try ResourceBudget(
                id: CoordinatorSample.artifact("budget.unusable-temporary-storage"),
                schemaVersion: .v1,
                target: .mainApplication,
                hardLimits: try ResourceMetric.requiredMetrics(for: .mainApplication)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        try ResourceLimitEntry(
                            metric: metric,
                            limit: metric.isCategorical
                                ? .thermal(maximumState: .fair)
                                : .numeric(
                                    value: CoordinatorSample.positive(
                                        metric == .temporaryStorage ? subByte : 1_000_000
                                    ),
                                    unit: CoordinatorSample.limitUnit(for: metric)
                                ),
                            measurementConditions: CoordinatorSample.evidence(
                                "evidence.measurement.\(metric.rawValue)"
                            )
                        )
                    },
                validationPlan: CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
            )
        } catch {
            preconditionFailure("the unusable-storage budget fixture must be valid: \(error)")
        }
    }
}
