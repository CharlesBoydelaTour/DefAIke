import DefAIkeDomain
import DefAIkePresentation
import DefAIkeProvenanceAPI
import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeApplication

// Task 15.3. One coherent synthetic version tuple reaching enabled ingest, and each of the
// five blocking classes refusing before any analysis work happens.
//
// "Reach enabled ingest" is not a phrase about a screen. `ReleaseAdmission`'s initializer is
// `fileprivate` to `StartupPreflight.swift` with exactly one call site — after step 7, with
// every gate passed — so *holding* one is the evidence. `AnalysisSessionBinder.init(admission:)`
// and `BoundAnalysisSession.snapshot(accepting:of:under:)` both require it. So the positive
// control here is: run the real seven-step gate, obtain a real admission, and bind a session
// through it. Nothing in this file constructs an admission by any other route, because there is
// no other route.
//
// The negative side is measured the same way, which is what makes "blocks before analysis"
// checkable rather than asserted. Every refusal is checked for three things at once: the gate
// threw, the thrown value is a `PreflightFailure` carrying one named cause, and the shared
// `PortCallRecorder` recorded no evidence-producing port call — `producedNoEvidenceWork` is
// exactly "no validate, preprocess, loadModel, infer, calibrate, provenanceAnalyze, or fuse".
// A refused startup therefore did not merely fail to *finish* analysis; it never began one.
//
// **Not everything this task names is reachable from a package test, and the unreachable parts
// are reported rather than simulated.** Three groups:
//
//   * The Share Extension's own eight-gate `ShareExtensionPreflight` and its
//     `ShareExtensionAdmission` live in `ios/DefAIkeShareExtension/`, which is an Xcode target
//     and not a SwiftPM target. It cannot be imported here at all. The boundary test
//     `theExtensionGateIsOutsideThisPackage`
//     records that as a fact about the checkout instead of pretending to cover it.
//   * `MainAppReleaseProvisioning`, `UnprovisionedReleaseInput`,
//     `UnprovisionedPolicyArtifactStore`,
//     `AdmittedMainApp`, and 12.3's linked-vs-provisioned adapter check live in
//     `ios/DefAIkeApp/Shared/`, likewise outside the package. The *behaviour* of the load-bearing
//     gap is reproduced here with a local store that refuses identically
//     (`AbsentPolicyArtifactStore`), and the absence itself is asserted over source text.
//   * `ParityRunBinding` (DefAIkeReleaseValidation) and `ReleaseSelfTestExecuting`
//     (DefAIkeModelBundle) are in package modules this test target does not depend on, and
//     12.4's note is explicit that no dependency edge may be added. Their absence is asserted
//     over source text; their behaviour is covered at the level this target can reach.
//
// **No value in this file is an approved release input.** Every artifact is built from
// `CoordinatorSample`'s synthetic placeholders, whose own header says the same thing. No
// signature is verified, no digest is streamed, no self-test is executed, no compiled model is
// loaded, and no test asserts that a value here is *correct* — only that the gate compares it.

// MARK: - Which artifact a probe leaves out

/// One artifact a probe can decline to register, so "absent" is a real absence rather than a
/// value that happens to disagree.
enum ProbeArtifact: String, CaseIterable, Sendable {
    case capabilityManifest
    case deviceAllowlist
    case lifecyclePolicy
    case extensionExecutionPolicy
    case resourceBudgets
    case bundleVerificationPolicy
    case preprocessingContract
    case calibrationPolicy
    case verdictCopyCatalog
    case provenancePolicy
    case fusionRule
}

// MARK: - The probe

/// A built release plus the real gate over it.
struct PreflightProbe {
    let preflight: StartupPreflight
    let policies: InMemoryArtifactStore
    let bundles: StubModelBundleManager
    let cleanup: FakeSessionDataDeleter
    let ephemeral: InMemoryEphemeralStore
    let recorder: PortCallRecorder
    let bundle: BoundModelBundle
    let manifest: ReleaseCapabilityManifest
    let allowlist: ReleaseApprovedDeviceAllowlist

    /// Runs all seven steps with this probe's ports.
    func run() async throws(PreflightFailure) -> ReleaseAdmission {
        try await preflight.run(policies: policies, bundles: bundles, cleanup: cleanup)
    }
}

enum PreflightProbeBuilder {
    /// Builds a coherent release and applies only the overrides a test supplies.
    ///
    /// Everything not overridden is derived from `CoordinatorSample`, so a test that changes one
    /// thing cannot accidentally leave a second disagreement behind and refuse for the wrong
    /// reason. The recorder is shared by the artifact store, the bundle manager, and the cleanup
    /// double, which is what makes `producedNoEvidenceWork` meaningful.
    static func make(
        provenance: Bool = false,
        fusion: Bool = false,
        device: DeviceContext? = nil,
        manifest manifestOverride: ReleaseCapabilityManifest? = nil,
        allowlist allowlistOverride: ReleaseApprovedDeviceAllowlist? = nil,
        verdictCopyCatalog catalogOverride: ApprovedVerdictCopyCatalog? = nil,
        bundle bundleOverride: BoundModelBundle? = nil,
        omitting: Set<ProbeArtifact> = [],
        activate: Bool = true,
        activationFailure: StubModelBundleManager.ActivationFailurePoint? = nil,
        embeddedBundle: String = CoordinatorSample.bundleID,
        target: ExecutionTarget = .mainApplication
    ) async throws -> PreflightProbe {
        let manifest = manifestOverride
            ?? CoordinatorSample.capabilityManifest(provenance: provenance, fusion: fusion)
        let allowlist = allowlistOverride
            ?? CoordinatorSample.allowlist(provenance: provenance, fusion: fusion)
        let catalog = catalogOverride ?? CoordinatorSample.copyCatalog()

        let recorder = PortCallRecorder()
        let policies = InMemoryArtifactStore(recorder: recorder)
        if !omitting.contains(.capabilityManifest) { await policies.register(manifest) }
        if !omitting.contains(.deviceAllowlist) { await policies.register(allowlist) }
        if !omitting.contains(.lifecyclePolicy) {
            await policies.register(CoordinatorSample.lifecyclePolicy())
        }
        if !omitting.contains(.extensionExecutionPolicy) {
            await policies.register(CoordinatorSample.extensionExecutionPolicy())
        }
        if !omitting.contains(.resourceBudgets) {
            await policies.register(CoordinatorSample.budgetSet())
        }
        if !omitting.contains(.bundleVerificationPolicy) {
            await policies.register(CoordinatorSample.verificationPolicy())
        }
        if !omitting.contains(.preprocessingContract) {
            await policies.register(CoordinatorSample.preprocessingContract())
        }
        if !omitting.contains(.calibrationPolicy) {
            await policies.register(CoordinatorSample.calibrationPolicy())
        }
        if !omitting.contains(.verdictCopyCatalog) { await policies.register(catalog) }
        if provenance, !omitting.contains(.provenancePolicy) {
            await policies.register(CoordinatorSample.provenancePolicy())
        }
        if fusion, !omitting.contains(.fusionRule) {
            await policies.register(CoordinatorSample.fusionRule())
        }

        let bundle = bundleOverride
            ?? CoordinatorSample.boundBundle(provenance: provenance, fusion: fusion)
        let bundles = StubModelBundleManager(recorder: recorder)
        if activate {
            await bundles.installAndActivate(bundle)
        } else {
            await bundles.install(bundle)
        }
        if let activationFailure {
            await bundles.failActivation(of: bundle.bundleID, at: activationFailure)
        }

        let clock = VirtualSessionClock()
        let ephemeral = InMemoryEphemeralStore(clock: clock)
        let cleanup = FakeSessionDataDeleter(
            store: ephemeral,
            clock: clock,
            recorder: recorder
        )

        return PreflightProbe(
            preflight: StartupPreflight(
                device: device ?? CoordinatorSample.deviceContext(),
                composition: CoordinatorSample.composition(
                    provenance: provenance,
                    fusion: fusion
                ),
                capabilityManifest: CoordinatorSample.artifact(
                    CoordinatorSample.capabilityManifestID
                ),
                verdictCopyCatalog: CoordinatorSample.artifact(CoordinatorSample.copyCatalogID),
                embeddedBundle: Fixture.bundleID(embeddedBundle),
                target: target
            ),
            policies: policies,
            bundles: bundles,
            cleanup: cleanup,
            ephemeral: ephemeral,
            recorder: recorder,
            bundle: bundle,
            manifest: manifest,
            allowlist: allowlist
        )
    }
}

// MARK: - Overridable artifact pieces

/// Fixture pieces `CoordinatorSample` does not expose an override for.
///
/// Deliberately additive: nothing in `AnalysisCoordinatorFixtures.swift` is modified, and each
/// builder here mirrors that file's shape with exactly one field opened up.
enum ProbeArtifacts {
    /// Gate evidence with every one of the 22 mandatory gates declared not applicable.
    ///
    /// Constructible today, which is the finding `allGatesWaivedIsAdmitted` pins.
    static func allGatesWaived() -> [GateResultReference] {
        do {
            return try DeviceGate.mandatoryGates
                .sorted { $0.rawValue < $1.rawValue }
                .map { gate in
                    try GateResultReference(
                        gate: gate,
                        applicability: .notApplicable(decision: CoordinatorSample.approval()),
                        outcome: .notExecuted,
                        result: CoordinatorSample.evidence("evidence.device.\(gate.rawValue)"),
                        environment: .physicalIPhone
                    )
                }
        } catch {
            preconditionFailure("an all-waived gate set must be constructible: \(error)")
        }
    }

    /// Coherent pixel-only gate evidence with `gate`'s result recorded in `environment`.
    ///
    /// A non-phone environment forces `outcome: .failed`, because
    /// `GateResultReference(outcome: .passed, environment: .developmentMac)` throws.
    static func gateEvidence(
        provenanceEnabled: Bool,
        recording gate: DeviceGate,
        in environment: ExecutionEnvironment,
        outcome: GateOutcome
    ) -> [GateResultReference] {
        do {
            return try DeviceGate.mandatoryGates
                .sorted { $0.rawValue < $1.rawValue }
                .map { current in
                    let applicable = !current.isProvenanceConditional || provenanceEnabled
                    if current == gate, applicable {
                        return try GateResultReference(
                            gate: current,
                            applicability: .applicable,
                            outcome: outcome,
                            result: CoordinatorSample.evidence(
                                "evidence.device.\(current.rawValue)"
                            ),
                            environment: environment
                        )
                    }
                    return try GateResultReference(
                        gate: current,
                        applicability: applicable
                            ? .applicable
                            : .notApplicable(decision: CoordinatorSample.approval()),
                        outcome: applicable ? .passed : .notExecuted,
                        result: CoordinatorSample.evidence("evidence.device.\(current.rawValue)"),
                        environment: .physicalIPhone
                    )
                }
        } catch {
            preconditionFailure("the gate evidence fixture must be constructible: \(error)")
        }
    }

    /// A version tuple with any element replaceable.
    static func versionTuple(
        capabilities: Set<CapabilityID>,
        appBuild: String = CoordinatorSample.appBuildID,
        modelBundle: String = CoordinatorSample.bundleID,
        fixtureSuite: String = CoordinatorSample.fixtureSuiteID,
        validationPlan: String = CoordinatorSample.validationPlanID,
        capabilityManifest: String = CoordinatorSample.capabilityManifestID,
        implementationVersions: [CapabilityImplementationEntry]? = nil
    ) -> ValidationVersionTuple {
        do {
            return try ValidationVersionTuple(
                appBuild: Fixture.appBuild(appBuild),
                modelBundle: Fixture.bundleID(modelBundle),
                fixtureSuite: CoordinatorSample.artifact(fixtureSuite),
                validationPlan: CoordinatorSample.artifact(validationPlan),
                capabilityManifest: CoordinatorSample.artifact(capabilityManifest),
                capabilities: capabilities,
                capabilityImplementationVersions: implementationVersions
                    ?? CoordinatorSample.implementationVersions(for: capabilities)
            )
        } catch {
            preconditionFailure("the version tuple fixture must be constructible: \(error)")
        }
    }

    /// One allowlist entry with any element replaceable.
    static func entry(
        identifier: String = CoordinatorSample.configurationID,
        capabilities: Set<CapabilityID>,
        hardware hardwareIdentifier: String = "iPhone17.1",
        appBuild: String = CoordinatorSample.appBuildID,
        versionTuple tupleOverride: ValidationVersionTuple? = nil,
        gateEvidence evidenceOverride: [GateResultReference]? = nil
    ) -> ApprovedDeviceConfiguration {
        do {
            return try ApprovedDeviceConfiguration(
                id: Fixture.configurationID(identifier),
                configuration: try CandidateDeviceConfiguration(
                    deviceModel: CoordinatorSample.text("Synthetic iPhone"),
                    hardwareIdentifier: CoordinatorSample.hardware(hardwareIdentifier),
                    osVersion: .iOS17,
                    appBuild: Fixture.appBuild(appBuild),
                    isAppleNeuralEngineCapable: true
                ),
                versionTuple: tupleOverride
                    ?? versionTuple(capabilities: capabilities, appBuild: appBuild),
                gateEvidence: evidenceOverride
                    ?? CoordinatorSample.gateEvidence(
                        provenanceEnabled: capabilities.contains(.contentCredentialValidation)
                    )
            )
        } catch {
            preconditionFailure("the allowlist entry fixture must be constructible: \(error)")
        }
    }

    static func allowlist(
        entries: [ApprovedDeviceConfiguration]
    ) -> ReleaseApprovedDeviceAllowlist {
        do {
            return try ReleaseApprovedDeviceAllowlist(
                id: CoordinatorSample.artifact(CoordinatorSample.allowlistID),
                schemaVersion: .v1,
                entries: entries,
                approval: CoordinatorSample.approval()
            )
        } catch {
            preconditionFailure("the allowlist fixture must be constructible: \(error)")
        }
    }

    /// A copy catalogue declaring a different compatibility identifier.
    static func copyCatalog(compatibility: String) -> ApprovedVerdictCopyCatalog {
        let coherent = CoordinatorSample.copyCatalog()
        do {
            return try ApprovedVerdictCopyCatalog(
                id: coherent.id,
                schemaVersion: .v1,
                compatibilityID: CoordinatorSample.artifact(compatibility),
                languageTag: coherent.languageTag,
                entries: coherent.entries,
                approval: coherent.approval
            )
        } catch {
            preconditionFailure("the copy catalogue fixture must be constructible: \(error)")
        }
    }

    /// A manifest whose policy compatibility set names a different copy compatibility.
    static func manifest(verdictCopyCompatibility: String) -> ReleaseCapabilityManifest {
        let coherent = CoordinatorSample.capabilityManifest(provenance: false, fusion: false)
        do {
            let compatibility = coherent.policyCompatibility
            return try ReleaseCapabilityManifest(
                id: coherent.id,
                schemaVersion: .v1,
                appBuild: coherent.appBuild,
                compositionIdentifier: coherent.compositionIdentifier,
                compiledCapabilities: coherent.compiledCapabilities,
                implementationVersions: coherent.implementationVersions,
                approvedConfigurationAllowlist: coherent.approvedConfigurationAllowlist,
                approvedBundleCatalog: coherent.approvedBundleCatalog,
                policyCompatibility: try PolicyCompatibilitySet(
                    preprocessingContract: compatibility.preprocessingContract,
                    calibrationPolicy: compatibility.calibrationPolicy,
                    lifecyclePolicy: compatibility.lifecyclePolicy,
                    extensionExecutionPolicy: compatibility.extensionExecutionPolicy,
                    mainApplicationResourceBudget: compatibility.mainApplicationResourceBudget,
                    shareExtensionResourceBudget: compatibility.shareExtensionResourceBudget,
                    bundleVerificationPolicy: compatibility.bundleVerificationPolicy,
                    verdictCopyCompatibility: CoordinatorSample.artifact(
                        verdictCopyCompatibility
                    ),
                    provenancePolicy: compatibility.provenancePolicy,
                    fusionRule: compatibility.fusionRule
                ),
                approval: coherent.approval
            )
        } catch {
            preconditionFailure("the manifest fixture must be constructible: \(error)")
        }
    }

    /// Component versions with one reference pointed somewhere else.
    static func componentVersions(
        preprocessingContract: String = CoordinatorSample.preprocessingContractID,
        calibrationPolicy: String = CoordinatorSample.calibrationPolicyID,
        verdictCopyCompatibility: String = CoordinatorSample.copyCompatibilityID
    ) -> BundleComponentVersions {
        BundleComponentVersions(
            coreMLModel: CoordinatorSample.artifact(CoordinatorSample.coreMLComponentID),
            preprocessingContract: CoordinatorSample.artifact(preprocessingContract),
            calibrationPolicy: CoordinatorSample.artifact(calibrationPolicy),
            evidenceScope: CoordinatorSample.artifact(CoordinatorSample.evidenceScopeID),
            verdictCopyCompatibility: CoordinatorSample.artifact(verdictCopyCompatibility),
            selfTestSpecification: CoordinatorSample.artifact("component.self-tests")
        )
    }

    /// An activation receipt whose two outcomes a test sets.
    ///
    /// `BoundModelBundle` accepts only a receipt with both passing, so a failed self-test makes
    /// `boundBundle` return `nil` rather than a bundle with a recorded failure.
    static func receipt(
        signature: GateOutcome = .passed,
        selfTest: GateOutcome = .passed
    ) -> ActivationReceipt {
        do {
            return try ActivationReceipt(
                id: CoordinatorSample.artifact("receipt.activation.probe"),
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(CoordinatorSample.bundleID),
                verificationPolicy: CoordinatorSample.artifact(
                    CoordinatorSample.verificationPolicyID
                ),
                verifiedManifestDigest: CoordinatorSample.digest("manifest"),
                verifiedArtifactDigests: [CoordinatorSample.digestRecord()],
                signatureOutcome: signature,
                selfTestOutcome: selfTest,
                deviceContext: CoordinatorSample.deviceContext(),
                activationGeneration: CoordinatorSample.count(1),
                activatedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        } catch {
            preconditionFailure("the activation receipt fixture must be constructible: \(error)")
        }
    }

    /// A bundle whose receipt or component versions a test sets. `nil` when the receipt is not
    /// bindable, which is itself an outcome a test asserts.
    static func boundBundle(
        componentVersions overrides: BundleComponentVersions? = nil,
        receipt receiptOverride: ActivationReceipt? = nil
    ) -> BoundModelBundle? {
        let manifest: ModelBundleManifest
        do {
            manifest = try ModelBundleManifest(
                schemaVersion: .v1,
                bundleID: Fixture.bundleID(CoordinatorSample.bundleID),
                modelIdentity: RequiredPixelModel.identity,
                modelFormat: try ModelFormatDescriptor(
                    programKind: .mlProgram,
                    computePrecision: .float16,
                    minimumOS: .iOS17
                ),
                inputContract: CoordinatorSample.modelInputContract(),
                outputContract: CoordinatorSample.modelOutputContract(),
                componentVersions: overrides ?? CoordinatorSample.componentVersions(),
                artifacts: [CoordinatorSample.digestRecord()],
                compatibility: try CompatibilityMatrix(
                    compatibleAppBuilds: [Fixture.appBuild(CoordinatorSample.appBuildID)],
                    requiredCapabilities: [.pixelAnalysis],
                    minimumOS: .iOS17
                ),
                upstreamBoundaryMetadata: CoordinatorSample.upstreamMetadata(),
                signingKey: CoordinatorSample.signingKey()
            )
        } catch {
            preconditionFailure("the bundle manifest fixture must be constructible: \(error)")
        }
        return BoundModelBundle(manifest: manifest, receipt: receiptOverride ?? receipt())
    }
}

// MARK: - A store that has nothing

/// A `PolicyArtifactReading` for a build with no installed signed artifact store.
///
/// Behaviourally identical to `UnprovisionedPolicyArtifactStore` in `ios/DefAIkeApp/Shared/`
/// and `UnprovisionedExtensionPolicyStore` in `ios/DefAIkeShareExtension/Sources/`, neither of
/// which a package test can import. Every member reports `ReleaseArtifactError.storeUnavailable`,
/// which is the port's own vocabulary for exactly this condition, and no member returns a value:
/// no policy, deadline, budget, boundary, allowlist entry, or trust rule can enter through it.
///
/// This is the load-bearing gap of 12.1's eleven: `PolicyArtifactReading` has no shipping adapter
/// anywhere in the repository, so a real build refuses at step 2 and the whole analysis graph
/// downstream of an admission is unreachable.
struct AbsentPolicyArtifactStore: PolicyArtifactReading {
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

// MARK: - The checkout

/// Locates the repository so a probe can answer questions about *files*.
///
/// Several inputs this task has to measure are absent artifacts, not wrong values, and a
/// value-level test cannot see a file that does not exist. The root is found by walking up from
/// this file to the directory holding `Package.swift` and then to the directory holding `ios/`,
/// so it does not depend on the working directory a runner chose. When the walk fails the tests
/// fail: an unanswerable question must not read as a passing one.
enum ReleaseCheckout {
    static let packageRoot: URL? = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let manifest = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// The directory holding `ios/`, which is the repository root.
    static let repositoryRoot: URL? = {
        guard var directory = packageRoot else { return nil }
        while directory.path != "/" {
            let ios = directory.appending(path: "ios")
            let package = ios.appending(path: "DefAIkePackage/Package.swift")
            if FileManager.default.fileExists(atPath: package.path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    static var iosRoot: URL? { repositoryRoot?.appending(path: "ios") }

    /// Every file under `directory` matching `predicate`, sorted by path.
    static func files(under directory: URL, matching predicate: (URL) -> Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { !$0.path.contains("/.build/") && !$0.path.contains("/.swiftpm/") }
            .filter(predicate)
            .sorted { $0.path < $1.path }
    }

    /// Every Swift file under `ios/`, excluding build products.
    static func swiftSources() -> [URL] {
        guard let root = iosRoot else { return [] }
        return files(under: root) { $0.pathExtension == "swift" }
    }

    /// Source text with `//` comment bodies removed.
    ///
    /// Mandatory before any token scan: these sources discuss most of the interesting tokens by
    /// name in their own documentation, and an unstripped scan reads the prose and gets the
    /// wrong answer.
    static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The raw text of one file, relative to `ios/`, or `nil` when it is not there.
    ///
    /// Raw rather than comment-stripped, because the callers that need it are checking compiler
    /// directives. A directive is not a comment, and stripping would not remove it, but the
    /// distinction is worth naming so nobody routes this through `strippingComments`.
    static func rawSource(_ relativePath: String) throws -> String? {
        guard let root = iosRoot else { return nil }
        let url = root.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Paths, relative to `ios/`, of every Swift file whose comment-stripped text declares a
    /// conformance to `protocolName`.
    static func conformanceDeclarations(to protocolName: String) throws -> [String] {
        guard let root = iosRoot else { return [] }
        let prefix = root.path + "/"
        var matches: [String] = []
        for url in swiftSources() {
            let code = strippingComments(try String(contentsOf: url, encoding: .utf8))
            guard code.contains(": \(protocolName)")
                || code.contains(", \(protocolName)")
                || code.contains("\(protocolName), ")
            else {
                continue
            }
            matches.append(String(url.path.dropFirst(prefix.count)))
        }
        return matches.sorted()
    }
}

// MARK: - Shared refusal oracle

/// Runs a probe, requires it to refuse, and requires the refusal to have done no analysis work.
///
/// The second half is the part that makes "before analysis" a measurement. `producedNoEvidenceWork`
/// is the recorder's own disjointness check against `PortCall.evidenceProducingCalls`, so it
/// covers validate, preprocess, loadModel, infer, calibrate, provenanceAnalyze, and fuse at once.
@discardableResult
private func expectBlockedBeforeAnalysis(
    _ probe: PreflightProbe,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: (PreflightFailure) -> Bool
) async -> PreflightFailure? {
    // The sample builders throw untyped errors, so nothing but the gate call is inside the `do`:
    // a typed-throws `do` with a downcasting `catch` crashes this compiler.
    do {
        _ = try await probe.run()
        Issue.record("expected the startup gate to refuse", sourceLocation: sourceLocation)
        return nil
    } catch {
        #expect(predicate(error), "unexpected refusal: \(error)", sourceLocation: sourceLocation)
        let didAnalysisWork = !probe.recorder.producedNoEvidenceWork
        #expect(
            !didAnalysisWork,
            "a refused startup must reach no evidence-producing port",
            sourceLocation: sourceLocation
        )
        return error
    }
}

// MARK: - 1. The positive control

@Suite("Release preflight: a coherent version tuple reaches enabled ingest")
struct CoherentReleaseReachesIngestTests {
    @Test("A coherent pixel-only tuple yields a real admission and a bound session")
    func pixelOnlyReleaseReachesIngest() async throws {
        // The whole file rests on this. If a coherent tuple cannot reach an admission, every
        // "blocked" assertion below is vacuous, because nothing would ever have been admitted.
        let probe = try await PreflightProbeBuilder.make()
        let admission = try await probe.run()

        // Step 7 was reached: the admission carries the matched entry, the manifest version, the
        // verified bundle, and this target's plan.
        #expect(admission.target == .mainApplication)
        #expect(admission.configuration.capabilityManifest.id == probe.manifest.id)
        #expect(admission.approvedConfiguration.id == probe.allowlist.entries[0].id)
        #expect(admission.bundle.bundleID == probe.bundle.bundleID)
        #expect(admission.bundle.integrity.status == .verified)
        #expect(!admission.enablesProvenance)
        #expect(!admission.enablesFusion)
        let expectedSuite = CoordinatorSample.artifact(CoordinatorSample.fixtureSuiteID)
        #expect(admission.boundFixtureSuite == expectedSuite)
        let expectedPlan = CoordinatorSample.artifact(CoordinatorSample.validationPlanID)
        #expect(admission.boundValidationPlan == expectedPlan)
        // Nothing was abandoned, which is a completed cleanup rather than a skipped one.
        #expect(admission.startupCleanup.isEmpty)
        #expect(probe.recorder.didCall(PortCallKind.deleteAbandonedData))

        // Ingest is now reachable: a binder exists only because an admission does.
        let binder = AnalysisSessionBinder(admission: admission, bundles: probe.bundles)
        let sessionID = PortValue.sessionID("session-15-3-pixel")
        let asset = PortValue.asset(route: .photosPicker, sessionID: sessionID)
        let session = try await binder.bind(accepting: asset)

        #expect(session.sessionID == sessionID)
        #expect(session.modelBundleID == probe.bundle.bundleID)
        #expect(session.integrityStatus == .verified)
        #expect(session.binding.capabilityManifestID == probe.manifest.id)
        #expect(session.binding.deviceConfigurationID == admission.approvedConfiguration.id)
        #expect(session.binding.appBuildID == admission.context.device.appBuild)
        let boundContract = session.binding.preprocessingContractID
        #expect(boundContract == admission.configuration.preprocessingContract.id)
        let boundCalibration = session.binding.calibrationPolicyID
        #expect(boundCalibration == admission.configuration.calibrationPolicy.id)
        let boundCopy = session.binding.verdictCopyCompatibilityID
        #expect(boundCopy == admission.configuration.verdictCopyCatalog.compatibilityID)
        let mainBudget = admission.configuration.resourceBudgets.mainApplication
        #expect(session.binding.resourceBudgetID == mainBudget.id)
        #expect(!session.enablesProvenance)
        #expect(!session.enablesFusion)

        // And the snapshot the binder keeps is the one it returned.
        let retained = await binder.boundSession(sessionID)
        #expect(retained == session)
    }

    @Test("A coherent provenance and fusion tuple reaches ingest with both lanes enabled")
    func provenanceAndFusionReleaseReachesIngest() async throws {
        let probe = try await PreflightProbeBuilder.make(provenance: true, fusion: true)
        let admission = try await probe.run()
        #expect(admission.enablesProvenance)
        #expect(admission.enablesFusion)

        let binder = AnalysisSessionBinder(admission: admission, bundles: probe.bundles)
        let sessionID = PortValue.sessionID("session-15-3-full")
        let asset = PortValue.asset(route: .shareExtension, sessionID: sessionID)
        let session = try await binder.bind(accepting: asset)
        #expect(session.enablesProvenance)
        #expect(session.enablesFusion)
        let policyID = CoordinatorSample.artifact(CoordinatorSample.provenancePolicyID)
        #expect(session.provenancePolicy?.id == policyID)
        let ruleID = CoordinatorSample.artifact(CoordinatorSample.fusionRuleID)
        #expect(session.fusionRule?.id == ruleID)
    }

    @Test("The same coherent tuple reaches ingest through the shared coordinator harness")
    func theReferenceHarnessAlsoReachesIngest() async throws {
        // `CoordinatorRelease.build` runs the same real seven-step gate. Crossing the two paths
        // guards against the probe builder above having quietly diverged into something the real
        // gate would not admit.
        let release = try await CoordinatorRelease.build()
        let binder = release.binder()
        let asset = try await release.acceptedIngest(sessionID: "session-15-3-ref")
        let session = try await binder.bind(accepting: asset)
        #expect(session.modelBundleID == release.bundle.bundleID)
        #expect(session.resourceBudget.id == release.mainBudget.id)
        #expect(release.admission.configuration.lifecyclePolicy.id == release.lifecyclePolicy.id)
    }

    @Test("A coherent tuple also binds approved copy, so the release is presentable")
    func theCoherentReleaseBindsApprovedCopy() async throws {
        // A release that reaches ingest and then cannot address any approved surface is not a
        // usable release. This is the downstream half of the positive control.
        let probe = try await PreflightProbeBuilder.make()
        let admission = try await probe.run()
        let binder = AnalysisSessionBinder(admission: admission, bundles: probe.bundles)
        let asset = PortValue.asset(sessionID: PortValue.sessionID("session-15-3-copy"))
        let session = try await binder.bind(accepting: asset)

        let copy = try ApprovedCopyBinding.bind(
            catalog: admission.configuration.verdictCopyCatalog,
            session: session.binding,
            capabilities: admission.configuration.capabilityManifest,
            fusionRule: nil
        )
        #expect(copy.sessionID == session.sessionID)
        let compatibility = session.binding.verdictCopyCompatibilityID
        #expect(copy.compatibilityID == compatibility)
    }
}

// MARK: - 2. Absent placeholders and external approvals

@Suite("Release preflight blocks on each absent placeholder or external approval")
struct AbsentReleaseInputBlocksTests {
    @Test("A build with no installed signed artifact store refuses at step 2")
    func noPolicyArtifactStoreBlocks() async throws {
        // The load-bearing gap of 12.1's eleven, reproduced behaviourally. The gate never gets
        // past `ReleaseConfiguration.load`, so no manifest, allowlist, entry, bundle, or budget
        // is ever read, and no admission exists for a binder to be built from.
        let probe = try await PreflightProbeBuilder.make()
        let absent = AbsentPolicyArtifactStore()
        var refusal: PreflightFailure?
        do {
            _ = try await probe.preflight.run(
                policies: absent,
                bundles: probe.bundles,
                cleanup: probe.cleanup
            )
            Issue.record("a build with no artifact store must refuse")
        } catch {
            refusal = error
        }
        let observed = try #require(refusal)
        #expect(observed == .artifactUnavailable(.storeUnavailable))
        #expect(probe.recorder.producedNoEvidenceWork)
        // And cleanup, which is step 5, was never reached either.
        #expect(!probe.recorder.didCall(PortCallKind.deleteAbandonedData))
    }

    @Test("No shipping PolicyArtifactReading adapter exists anywhere in the repository")
    func noShippingArtifactStoreAdapterExists() throws {
        // The absence itself, not a stand-in for it. Asserted over comment-stripped source text
        // because the sources discuss the port by name in their own documentation.
        let sources = ReleaseCheckout.swiftSources()
        #expect(!sources.isEmpty, "the checkout must be locatable")
        let conformances = try ReleaseCheckout.conformanceDeclarations(to: "PolicyArtifactReading")
        // Five conformances exist and not one of them is an adapter over signed artifacts: the
        // nonshipping in-memory test store, the two refusal-only stores in the Xcode targets
        // that throw `.storeUnavailable` from every member, `AbsentPolicyArtifactStore` in this
        // file, which is a fourth refusal-only store, and the development store in
        // `DevelopmentModelBundle.swift`, which reads values a DEBUG binary constructed in memory.
        // The exact set is asserted so a future adapter shows up here as a failure rather than
        // passing unnoticed — which is exactly how the development store showed up.
        let expected = [
            "DefAIkeApp/Shared/DevelopmentModelBundle.swift",
            "DefAIkeApp/Shared/MainAppReleaseProvisioning.swift",
            "DefAIkePackage/Sources/DefAIkeTestSupport/InMemoryArtifactStore.swift",
            "DefAIkePackage/Tests/DefAIkeApplicationTests/"
                + "ReleasePreflightAdmissionIntegrationTests.swift",
            "DefAIkeShareExtension/Sources/ShareExtensionReleaseProvisioning.swift",
        ]
        #expect(conformances == expected, "unexpected conformance set: \(conformances)")
        // The development store is the one conformance that returns artifacts rather than refusing,
        // so the guarantee it must carry is different: it cannot exist in a Release build at all.
        // Asserted over the raw source rather than the comment-stripped text, because `#if DEBUG`
        // is a directive and not a comment, and asserted as a file-level property so a later edit
        // that moves the conformance outside the directive fails here.
        try requireDebugOnly("DefAIkeApp/Shared/DevelopmentModelBundle.swift")
        try requireDebugOnly("DefAIkeApp/Shared/DevelopmentProvisioning.swift")
        // And nothing under a shipping package module conforms.
        let shipping = conformances.filter {
            $0.hasPrefix("DefAIkePackage/Sources/") && !$0.contains("DefAIkeTestSupport")
        }
        #expect(shipping.isEmpty, "a shipping module now reads signed artifacts: \(shipping)")
    }

    /// Requires every line of code in `relativePath` to sit inside one top-level `#if DEBUG`.
    ///
    /// The check is deliberately crude and therefore hard to satisfy by accident: the first
    /// non-blank, non-comment line must be `#if DEBUG`, the last must be `#endif`, and no `#else`
    /// may appear at column zero in between. A file shaped that way has no symbol in a Release
    /// build, whatever it declares.
    private func requireDebugOnly(
        _ relativePath: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let source = try #require(
            try ReleaseCheckout.rawSource(relativePath),
            "\(relativePath) must exist",
            sourceLocation: sourceLocation
        )
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }

        #expect(lines.first == "#if DEBUG", "\(relativePath) must open with #if DEBUG",
            sourceLocation: sourceLocation)
        #expect(lines.last == "#endif", "\(relativePath) must close with #endif",
            sourceLocation: sourceLocation)
        // A top-level `#else` would give the Release build a second branch to compile.
        let topLevelElse = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0 == "#else" }
        #expect(!topLevelElse, "\(relativePath) must have no top-level #else",
            sourceLocation: sourceLocation)
    }

    @Test("Each absent policy artifact blocks ingest rather than being defaulted")
    func eachAbsentArtifactBlocks() async throws {
        // One probe per artifact the manifest's reference graph names. Absence is never a
        // permissive default: every one is `notFound`, and the reported identifier is the one
        // the signed manifest named (Requirements 14.15 and 14.16).
        let omittable: [ProbeArtifact] = [
            .capabilityManifest,
            .deviceAllowlist,
            .lifecyclePolicy,
            .extensionExecutionPolicy,
            .resourceBudgets,
            .bundleVerificationPolicy,
            .preprocessingContract,
            .calibrationPolicy,
            .verdictCopyCatalog,
        ]
        for artifact in omittable {
            let probe = try await PreflightProbeBuilder.make(omitting: [artifact])
            await expectBlockedBeforeAnalysis(probe) { failure in
                guard case let .artifactUnavailable(error) = failure else { return false }
                guard case .notFound = error else { return false }
                return true
            }
        }
    }

    @Test("An absent conditional approval blocks the capability it would enable")
    func absentConditionalApprovalBlocks() async throws {
        // A provenance-enabled manifest binds a Provenance Policy by identifier. With the policy
        // absent the build refuses; it does not fall back to a pixel-only composition, because
        // the signed manifest says this build compiles a validator.
        let withoutPolicy = try await PreflightProbeBuilder.make(
            provenance: true,
            omitting: [.provenancePolicy]
        )
        await expectBlockedBeforeAnalysis(withoutPolicy) { failure in
            guard case let .artifactUnavailable(error) = failure else { return false }
            guard case .notFound = error else { return false }
            return true
        }
        let withoutRule = try await PreflightProbeBuilder.make(
            provenance: true,
            fusion: true,
            omitting: [.fusionRule]
        )
        await expectBlockedBeforeAnalysis(withoutRule) { failure in
            guard case let .artifactUnavailable(error) = failure else { return false }
            guard case .notFound = error else { return false }
            return true
        }
    }

    @Test("A present but rejected external approval blocks ingest")
    func rejectedExternalApprovalBlocks() async throws {
        // Presence is not approval. A rejected Provenance Feasibility decision is the sharpest
        // case, because the policy resolved and the validator is linked: only the decision says
        // no (Requirement 6.1).
        let rejected = CoordinatorSample.approval(.rejected)
        let allowlist = try ReleaseApprovedDeviceAllowlist(
            id: CoordinatorSample.artifact(CoordinatorSample.allowlistID),
            schemaVersion: .v1,
            entries: CoordinatorSample.allowlist(provenance: false, fusion: false).entries,
            approval: rejected
        )
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            failure == .unapprovedArtifact(
                field: "deviceAllowlist.approval",
                decision: .rejected
            )
        }
    }

    @Test("No private signed release artifact is packaged in this repository")
    func noPrivateSignedReleaseArtifactIsPackaged() throws {
        // The private release inputs remain absent. Two public resources are packaged: the English
        // String Catalog and the official C2PA public trust-list snapshot. The latter is verified
        // against its pinned digest at runtime, but it is not a DefAIke-signed release admission
        // artifact. No signed capability manifest, device allowlist, validation plan, release
        // fixture suite, model-parity fixture, fusion rule, or signature KAT is present.
        let root = try #require(ReleaseCheckout.iosRoot)
        let sourcesRoot = root.appending(path: "DefAIkePackage/Sources")
        let resources = ReleaseCheckout.files(under: sourcesRoot) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: $0.path,
                isDirectory: &isDirectory
            )
            return exists && !isDirectory.boolValue && $0.pathExtension != "swift"
        }
        let relative = resources.map { String($0.path.dropFirst(sourcesRoot.path.count + 1)) }
        #expect(
            relative == [
                "DefAIkePresentation/ApprovedCopy/Localizable.xcstrings",
                "DefAIkeProvenanceC2PA/Trust/C2PA-TRUST-LIST.pem",
            ],
            "unexpected packaged resource set: \(relative)"
        )
        // The only payload-like extension is that public trust-list snapshot.
        let payloads = ReleaseCheckout.files(under: root) {
            ["json", "cbor", "pem", "cer", "der", "sig", "npy"].contains($0.pathExtension)
        }
        let payloadPaths = payloads.map { String($0.path.dropFirst(root.path.count + 1)) }
        #expect(
            payloadPaths
                == ["DefAIkePackage/Sources/DefAIkeProvenanceC2PA/Trust/C2PA-TRUST-LIST.pem"],
            "unexpected artifact payloads: \(payloadPaths)"
        )
    }

    @Test("No root code-license or attribution-notice file exists")
    func noRootLicenseOrNoticeExists() throws {
        // Requirements 14.2, 14.4, and 14.5. This is an external legal decision, and a test must
        // not manufacture one — so the finding is that the file is absent and public
        // distribution stays blocked, not that some placeholder terms are acceptable.
        let root = try #require(ReleaseCheckout.repositoryRoot)
        let names = ["LICENSE", "LICENSE.md", "LICENSE.txt", "NOTICE", "NOTICE.md", "NOTICE.txt"]
        var present: [String] = []
        for name in names {
            let candidate = root.appending(path: name)
            if FileManager.default.fileExists(atPath: candidate.path) { present.append(name) }
        }
        #expect(present.isEmpty, "a license or notice file now exists: \(present)")
    }

    @Test("No privacy manifest is carried by either shipping target")
    func noPrivacyManifestExists() throws {
        // Requirement 9.18's packaging half. `PrivacyInfo.xcprivacy` is a release-controlled
        // declaration; its absence is an owed input, and nothing here writes one.
        let root = try #require(ReleaseCheckout.iosRoot)
        let manifests = ReleaseCheckout.files(under: root) {
            $0.lastPathComponent == "PrivacyInfo.xcprivacy"
        }
        #expect(manifests.isEmpty, "a privacy manifest now exists: \(manifests.map(\.path))")
    }
}

// MARK: - 3. Incompatible components

@Suite("Release preflight blocks on an incompatible component")
struct IncompatibleComponentBlocksTests {
    @Test("A copy catalogue declaring another compatibility identifier blocks the load")
    func copyCatalogCompatibilitySkewBlocks() async throws {
        // Two independently signed statements about one release: the manifest names a copy
        // compatibility identifier, the catalogue declares one. A disagreement means the
        // approved wording was reviewed against a different Model Bundle (Requirement 8.1).
        let probe = try await PreflightProbeBuilder.make(
            verdictCopyCatalog: ProbeArtifacts.copyCatalog(compatibility: "copy.other")
        )
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .artifactUnavailable(error) = failure else { return false }
            guard case let .invalid(schema) = error else { return false }
            return "\(schema)".contains("verdictCopyCatalog.compatibilityID")
        }
    }

    @Test("A manifest naming another copy compatibility identifier blocks the load")
    func manifestCompatibilitySkewBlocks() async throws {
        // The mirror direction: the catalogue is the coherent one and the manifest moved.
        let probe = try await PreflightProbeBuilder.make(
            manifest: ProbeArtifacts.manifest(verdictCopyCompatibility: "copy.other")
        )
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .artifactUnavailable(error) = failure else { return false }
            guard case .invalid = error else { return false }
            return true
        }
    }

    @Test("A bundle component version the policy set does not bind blocks ingest")
    func bundleComponentVersionSkewBlocks() async throws {
        // Three independent skews, one per component the bundle and the policy set both name.
        // Each is a release where the model was calibrated and described against different
        // policies than the ones governing this process (Requirements 10.7 and 10.9).
        let skews: [(BundleComponentVersions, String)] = [
            (
                ProbeArtifacts.componentVersions(preprocessingContract: "contract.other"),
                "activeBundle.componentVersions.preprocessingContract"
            ),
            (
                ProbeArtifacts.componentVersions(calibrationPolicy: "policy.other"),
                "activeBundle.componentVersions.calibrationPolicy"
            ),
            (
                ProbeArtifacts.componentVersions(verdictCopyCompatibility: "copy.other"),
                "activeBundle.componentVersions.verdictCopyCompatibility"
            ),
        ]
        for (components, expectedField) in skews {
            let bundle = try #require(
                ProbeArtifacts.boundBundle(componentVersions: components)
            )
            let probe = try await PreflightProbeBuilder.make(bundle: bundle)
            await expectBlockedBeforeAnalysis(probe) { failure in
                guard case let .identityMismatch(field, _, _) = failure else { return false }
                return field == expectedField
            }
        }
    }

    @Test("An active bundle incompatible with this build is not admitted")
    func incompatibleBundleBlocks() async throws {
        // Compatibility is the bundle's own statement about which builds it serves, checked
        // against the observed one. Nothing falls back to an older or unverified asset.
        let device = DeviceContext(
            hardwareIdentifier: CoordinatorSample.hardware(),
            osVersion: .iOS17,
            appBuild: Fixture.appBuild("build.other"),
            environment: .physicalIPhone
        )
        let probe = try await PreflightProbeBuilder.make(device: device)
        // Caught one step earlier than the bundle: the embedded manifest describes a build that
        // is not the one running, so nothing it says applies to this binary.
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .identityMismatch(field, _, _) = failure else { return false }
            return field == "capabilityManifest.appBuild"
        }
    }

    @Test("Downstream, incompatible copy is refused at binding rather than rendered")
    func approvedCopyBindingRefusesCompatibilitySkew() async throws {
        // This layer is *after* analysis, and it is included because the task names it: a
        // component skew that somehow survived preflight still cannot produce a rendered
        // sentence. It refuses a presentation, not an ingest.
        let probe = try await PreflightProbeBuilder.make()
        let admission = try await probe.run()
        let binder = AnalysisSessionBinder(admission: admission, bundles: probe.bundles)
        let asset = PortValue.asset(sessionID: PortValue.sessionID("session-15-3-skew"))
        let session = try await binder.bind(accepting: asset)
        let manifest = admission.configuration.capabilityManifest

        var catalogRefusal: PresentationCopyError?
        do {
            _ = try ApprovedCopyBinding.bind(
                catalog: ProbeArtifacts.copyCatalog(compatibility: "copy.other"),
                session: session.binding,
                capabilities: manifest,
                fusionRule: nil
            )
        } catch {
            catalogRefusal = error
        }
        let observedCatalog = try #require(catalogRefusal)
        let requiredCompatibility = session.binding.verdictCopyCompatibilityID
        #expect(
            observedCatalog == .compatibilityMismatch(
                source: .copyCatalog,
                expected: requiredCompatibility,
                found: CoordinatorSample.artifact("copy.other")
            )
        )

        var manifestRefusal: PresentationCopyError?
        do {
            _ = try ApprovedCopyBinding.bind(
                catalog: admission.configuration.verdictCopyCatalog,
                session: session.binding,
                capabilities: ProbeArtifacts.manifest(verdictCopyCompatibility: "copy.other"),
                fusionRule: nil
            )
        } catch {
            manifestRefusal = error
        }
        let observedManifest = try #require(manifestRefusal)
        #expect(
            observedManifest == .compatibilityMismatch(
                source: .capabilityManifest,
                expected: requiredCompatibility,
                found: CoordinatorSample.artifact("copy.other")
            )
        )
    }
}

// MARK: - 4. Failed release self-tests

@Suite("Release preflight blocks on a failed release self-test")
struct FailedSelfTestBlocksTests {
    @Test("A receipt recording a failed self-test cannot become a bound bundle at all")
    func failedSelfTestIsNotBindable() {
        // The structural half. `BoundModelBundle` accepts only a receipt whose signature *and*
        // self-test passed, so a failed self-test does not produce a bundle carrying a recorded
        // failure that some later check has to notice — it produces nothing (Requirement 10.12).
        let failedSelfTest = ProbeArtifacts.boundBundle(
            receipt: ProbeArtifacts.receipt(selfTest: .failed)
        )
        #expect(failedSelfTest == nil)
        let notExecuted = ProbeArtifacts.boundBundle(
            receipt: ProbeArtifacts.receipt(selfTest: .notExecuted)
        )
        #expect(notExecuted == nil, "an unexecuted self-test is not a passing one")
        let failedSignature = ProbeArtifacts.boundBundle(
            receipt: ProbeArtifacts.receipt(signature: .failed)
        )
        #expect(failedSignature == nil)
        // And the coherent pair does bind, so the three refusals above are not vacuous.
        #expect(ProbeArtifacts.boundBundle() != nil)
    }

    @Test("A self-test failure during activation blocks ingest with no analysis error")
    func failedSelfTestDuringActivationBlocks() async throws {
        // The behavioural half, at the level `StartupPreflight` sees it: nothing is active, the
        // embedded candidate is approved, and activation fails at the self-test step. The gate
        // reports `verifiedBundleUnavailable` and deliberately drops the port's fault, so a
        // failed gate can never surface as an `AnalysisError` (Requirements 10.12 and 10.16).
        let probe = try await PreflightProbeBuilder.make(
            activate: false,
            activationFailure: .selfTests
        )
        await expectBlockedBeforeAnalysis(probe) { failure in
            failure == .verifiedBundleUnavailable(
                expected: Fixture.bundleID(CoordinatorSample.bundleID)
            )
        }
        // Activation was attempted and refused; the active pointer is untouched.
        let expectedBundle = Fixture.bundleID(CoordinatorSample.bundleID)
        #expect(probe.recorder.didCall(.activateLocalCandidate(expectedBundle)))
        let active = await probe.bundles.activeBundle()
        #expect(active == nil)
    }

    @Test("Every verification failure point blocks equally, so none is a soft failure")
    func everyActivationFailurePointBlocks() async throws {
        for point in StubModelBundleManager.ActivationFailurePoint.allCases {
            let probe = try await PreflightProbeBuilder.make(
                activate: false,
                activationFailure: point
            )
            await expectBlockedBeforeAnalysis(probe) { failure in
                guard case .verifiedBundleUnavailable = failure else { return false }
                return true
            }
        }
    }

    @Test("No shipping release self-test executor exists")
    func noShippingSelfTestExecutorExists() throws {
        // 12.1's other load-bearing gap. `ModelBundleActivator` requires a
        // `ReleaseSelfTestExecuting`, and the only conformance in the repository is a test
        // double, so no real build can construct an activator at all — which is why the
        // behavioural probes above use the stub manager rather than the real activator.
        let conformances = try ReleaseCheckout.conformanceDeclarations(
            to: "ReleaseSelfTestExecuting"
        )
        let shipping = conformances.filter {
            $0.hasPrefix("DefAIkePackage/Sources/") && !$0.contains("DefAIkeTestSupport")
        }
        #expect(shipping.isEmpty, "a shipping self-test executor now exists: \(shipping)")
        #expect(
            conformances == [
                "DefAIkePackage/Tests/DefAIkeModelBundleTests/CompatibilityDoubles.swift"
            ],
            "unexpected executor conformance set: \(conformances)"
        )
    }
}

// MARK: - 5. Stale, foreign, and waived device results

@Suite("Release preflight and a stale or non-phone device result")
struct StaleDeviceResultTests {
    @Test("A passing result from a Mac or a simulator is not representable")
    func aNonPhonePassIsUnrepresentable() {
        // Requirement 13.16, enforced at the schema rather than at the release validator: a
        // development-Mac or simulator result is *classified*, not discarded, and the point
        // where it would become release evidence is the point where it is refused.
        for environment in [ExecutionEnvironment.developmentMac, .iOSSimulator] {
            var constructed = false
            do {
                _ = try GateResultReference(
                    gate: .rawLogitParity,
                    applicability: .applicable,
                    outcome: .passed,
                    result: CoordinatorSample.evidence("evidence.device.raw-logit-parity"),
                    environment: environment
                )
                constructed = true
            } catch {
                constructed = false
            }
            #expect(!constructed, "a passing \(environment.rawValue) result must be refused")
        }
    }

    @Test("A failed Mac result constructs and then fails the gate on this device")
    func aFailedMacResultBlocksIngest() async throws {
        // The other half of 13.16: the result is recordable, so a runner can say what it saw,
        // and it satisfies nothing. Two entries, so the refusal names *this* device's failing
        // gate rather than the whole allowlist.
        let macEvidence = ProbeArtifacts.gateEvidence(
            provenanceEnabled: false,
            recording: .warmAnalysisLatency,
            in: .developmentMac,
            outcome: .failed
        )
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(
                identifier: "configuration.other",
                capabilities: [.pixelAnalysis],
                hardware: "iPhone17.2"
            ),
            ProbeArtifacts.entry(
                capabilities: [.pixelAnalysis],
                gateEvidence: macEvidence
            ),
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .unsatisfiedDeviceGates(configuration, gates) = failure else {
                return false
            }
            let expectedID = Fixture.configurationID(CoordinatorSample.configurationID)
            return configuration == expectedID && gates == [.warmAnalysisLatency]
        }
    }

    @Test("An unexecuted mandatory gate is not a satisfied one")
    func anUnexecutedGateBlocksIngest() async throws {
        // "Missing" is never "pass". An applicable gate with no imported result is exactly the
        // stale-evidence case a release audit has to catch (Requirement 13.19).
        let missing = ProbeArtifacts.gateEvidence(
            provenanceEnabled: false,
            recording: .coldModelLoad,
            in: .physicalIPhone,
            outcome: .notExecuted
        )
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(capabilities: [.pixelAnalysis], gateEvidence: missing)
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            // Requirement 13.22 fires first: the only entry is not distributable, which is the
            // more accurate finding than "this device is not approved".
            guard case let .allowlistApprovesNoConfiguration(allowlist) = failure else {
                return false
            }
            return allowlist == CoordinatorSample.artifact(CoordinatorSample.allowlistID)
        }
    }

    @Test("An entry with all 22 mandatory gates waived is ADMITTED — a pinned defect")
    func allGatesWaivedIsAdmitted() async throws {
        // The sharpest thing this task can measure, and the answer is unwelcome.
        //
        // `GateResultReference.isSatisfied` returns `decision.isApproved` for the
        // `.notApplicable` case, and — unlike `ReleaseGateRecord` — it carries no "an
        // unconditional gate cannot be declared not applicable" check.
        // `ApprovedDeviceConfiguration.init` only cross-checks the *provenance-conditional*
        // gate's applicability against the version tuple, so nothing refuses an entry that
        // waives all 22.
        //
        // Consequence, measured below rather than argued: the entry constructs,
        // `unsatisfiedGates` is empty, `permitsDistribution` answers true, and
        // `StartupPreflight` hands back a real `ReleaseAdmission` with which a session binds —
        // while no physical-device gate ever ran. 14.8, 14.9, and 14.10 each pinned a facet of
        // this; this is the preflight facet.
        //
        // Reported, not fixed. The fix belongs in `GateResultReference` (or in
        // `ApprovedDeviceConfiguration.init`) and would change a schema every other suite
        // depends on.
        let waived = ProbeArtifacts.entry(
            capabilities: [.pixelAnalysis],
            gateEvidence: ProbeArtifacts.allGatesWaived()
        )
        #expect(waived.gateEvidence.count == 22)
        #expect(waived.unsatisfiedGates.isEmpty, "the defect: every waived gate reads satisfied")
        let unconditionalWaivers = waived.gateEvidence.filter {
            !$0.gate.isProvenanceConditional && !$0.applicability.isApplicable
        }
        #expect(unconditionalWaivers.count == 21)

        let allowlist = ProbeArtifacts.allowlist(entries: [waived])
        #expect(
            allowlist.permitsDistribution,
            "the defect: nothing ran and yet distribution is permitted"
        )

        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        let admission = try await probe.run()
        #expect(
            admission.approvedConfiguration.id == waived.id,
            "measured, not endorsed: preflight admits an all-waived entry"
        )
        // And ingest really is reachable from it, which is what makes the finding matter.
        let binder = AnalysisSessionBinder(admission: admission, bundles: probe.bundles)
        let asset = PortValue.asset(sessionID: PortValue.sessionID("session-15-3-waived"))
        let session = try await binder.bind(accepting: asset)
        #expect(session.modelBundleID == probe.bundle.bundleID)
        // Every gate result the admitted entry rests on records no execution at all.
        let outcomes = Set(admission.approvedConfiguration.gateEvidence.map(\.outcome))
        #expect(outcomes == [GateOutcome.notExecuted])
    }
}

// MARK: - 6. Mixed-version records

@Suite("Release preflight and mixed-version allowlist records")
struct MixedVersionRecordTests {
    @Test("Sibling entries under one manifest cannot mix fixture-suite versions")
    func mixedFixtureSuiteVersionsBlock() async throws {
        // The runtime half of Requirement 13.20 that *is* implemented. One release binds one
        // Release Fixture Suite version, so two versions under one manifest means the gate
        // evidence was pooled across releases.
        let sibling = ProbeArtifacts.entry(
            identifier: "configuration.other",
            capabilities: [.pixelAnalysis],
            hardware: "iPhone17.2",
            versionTuple: ProbeArtifacts.versionTuple(
                capabilities: [.pixelAnalysis],
                fixtureSuite: "suite.other"
            )
        )
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(capabilities: [.pixelAnalysis]),
            sibling,
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .mixedAllowlistVersions(field, values) = failure else { return false }
            return field == "deviceAllowlist.entries.versionTuple.fixtureSuite"
                && values == ["suite.fixtures", "suite.other"]
        }
    }

    @Test("Sibling entries under one manifest cannot mix Device Validation Plan versions")
    func mixedValidationPlanVersionsBlock() async throws {
        let sibling = ProbeArtifacts.entry(
            identifier: "configuration.other",
            capabilities: [.pixelAnalysis],
            hardware: "iPhone17.2",
            versionTuple: ProbeArtifacts.versionTuple(
                capabilities: [.pixelAnalysis],
                validationPlan: "plan.other"
            )
        )
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(capabilities: [.pixelAnalysis]),
            sibling,
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .mixedAllowlistVersions(field, values) = failure else { return false }
            return field == "deviceAllowlist.entries.versionTuple.validationPlan"
                && values == ["plan.device-validation", "plan.other"]
        }
    }

    @Test("Sibling entries disagreeing about appBuild are ADMITTED — a pinned defect")
    func mixedAppBuildAcrossSiblingsIsAdmitted() async throws {
        // `requireCoherentEntries` compares exactly two elements of the version tuple across
        // siblings, `fixtureSuite` and `validationPlan`. `appBuild` is not compared, and
        // `requireVersionTuple` never compares `entry.versionTuple.appBuild` against
        // `manifest.appBuild` either — the matched entry's build agrees only *transitively*,
        // because step 2 requires `manifest.appBuild == device.appBuild` and the allowlist
        // lookup matches on `versionTuple.appBuild`.
        //
        // So a sibling entry under this build's signed manifest may name a different
        // application build and preflight admits the release. That is a mixed-version record
        // by the plain reading of Requirement 13.20: one signed manifest, one fixture suite,
        // one plan, two application builds.
        //
        // 14.8 closed this at record level and reported that the preflight side still stood.
        // Measured here; the missing comparison is
        // `requireIdentity(tuple.appBuild, matches: manifest.appBuild)` in
        // `requireVersionTuple`, plus an `appBuild` set in `requireCoherentEntries`. Reported,
        // not fixed.
        let sibling = ProbeArtifacts.entry(
            identifier: "configuration.other-build",
            capabilities: [.pixelAnalysis],
            hardware: "iPhone17.1",
            appBuild: "build.other"
        )
        let matched = ProbeArtifacts.entry(capabilities: [.pixelAnalysis])
        let allowlist = ProbeArtifacts.allowlist(entries: [matched, sibling])

        // Both entries name this build's signed manifest, and one names a different build.
        let manifestID = CoordinatorSample.artifact(CoordinatorSample.capabilityManifestID)
        let siblingsOfThisManifest = allowlist.entries.filter {
            $0.versionTuple.capabilityManifest == manifestID
        }
        #expect(siblingsOfThisManifest.count == 2)
        let builds = Set(siblingsOfThisManifest.map { $0.versionTuple.appBuild.rawValue })
        #expect(builds == ["build.coordinator", "build.other"])

        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        let admission = try await probe.run()
        #expect(
            admission.approvedConfiguration.id == matched.id,
            "measured, not endorsed: preflight admits an allowlist that mixes application builds"
        )
        // The matched entry itself is coherent, which is exactly why the mix survives.
        let matchedBuild = admission.approvedConfiguration.versionTuple.appBuild
        #expect(matchedBuild == admission.configuration.capabilityManifest.appBuild)
    }

    @Test("An entry bound to another capability manifest cannot admit this build")
    func foreignCapabilityManifestBlocks() async throws {
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(
                capabilities: [.pixelAnalysis],
                versionTuple: ProbeArtifacts.versionTuple(
                    capabilities: [.pixelAnalysis],
                    capabilityManifest: "manifest.other"
                )
            )
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            failure == .identityMismatch(
                field: "allowlistEntry.versionTuple.capabilityManifest",
                expected: "manifest.capability",
                found: "manifest.other"
            )
        }
    }

    @Test("Gate evidence recorded at another implementation version cannot admit this build")
    func foreignImplementationVersionBlocks() async throws {
        // The tuple element that differs is only the per-capability implementation version, so
        // this is the narrowest mixed-version record preflight can be handed — and it is
        // refused. Preflight *does* reconcile `capabilityImplementationVersions`.
        let other = [
            CapabilityImplementationEntry(
                capability: .pixelAnalysis,
                version: CoordinatorSample.version("2.0.0")
            )
        ]
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(
                capabilities: [.pixelAnalysis],
                versionTuple: ProbeArtifacts.versionTuple(
                    capabilities: [.pixelAnalysis],
                    implementationVersions: other
                )
            )
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .capabilitySetMismatch(approved, compiled) = failure else {
                return false
            }
            return approved == ["pixel-analysis@1.0.0"] && compiled == ["pixel-analysis@2.0.0"]
        }
    }

    @Test("An entry validated against a Model Bundle the manifest does not approve is refused")
    func foreignModelBundleBlocks() async throws {
        let allowlist = ProbeArtifacts.allowlist(entries: [
            ProbeArtifacts.entry(
                capabilities: [.pixelAnalysis],
                versionTuple: ProbeArtifacts.versionTuple(
                    capabilities: [.pixelAnalysis],
                    modelBundle: "bundle.other"
                )
            )
        ])
        let probe = try await PreflightProbeBuilder.make(allowlist: allowlist)
        await expectBlockedBeforeAnalysis(probe) { failure in
            guard case let .identityMismatch(field, _, found) = failure else { return false }
            return field == "allowlistEntry.versionTuple.modelBundle" && found == "bundle.other"
        }
    }
}

// MARK: - 7. What this package cannot reach

@Suite("Release preflight coverage boundaries this package cannot cross")
struct PreflightCoverageBoundaryTests {
    @Test("The Share Extension's own eight-gate startup gate is outside this package")
    func theExtensionGateIsOutsideThisPackage() throws {
        // Stated as a fact about the checkout rather than as prose, because "we did not cover
        // it" and "it is not coverable from here" are different claims and only the second one
        // is true. `ShareExtensionPreflight` produces its own `ShareExtensionAdmission`, whose
        // initializer is `fileprivate` with one call site exactly as `ReleaseAdmission`'s is;
        // it lives in an Xcode target that no SwiftPM target names, so no package test can
        // import it, run it, or hold one of its admissions.
        let root = try #require(ReleaseCheckout.iosRoot)
        let gate = root.appending(
            path: "DefAIkeShareExtension/Sources/ShareExtensionStartupGate.swift"
        )
        #expect(FileManager.default.fileExists(atPath: gate.path))
        let code = ReleaseCheckout.strippingComments(
            try String(contentsOf: gate, encoding: .utf8)
        )
        #expect(code.contains("struct ShareExtensionAdmission"))
        #expect(code.contains("fileprivate init("))
        let construction = "return ShareExtensionAdmission("
        let constructions = code.components(separatedBy: construction).count - 1
        #expect(constructions == 1, "the extension admission must have exactly one call site")

        // And it is not inside the package, so no `import` could reach it. The manifest does
        // mention the string once, as the *product* `DefAIkeShareExtensionKit` — which is
        // composed of `DefAIkeDomain` and `DefAIkeSharedTransfer` and contains none of the
        // extension's own sources. No SwiftPM target is named `DefAIkeShareExtension`, which
        // is the claim that matters.
        #expect(!gate.path.contains("/DefAIkePackage/"))
        let packageManifest = root.appending(path: "DefAIkePackage/Package.swift")
        let manifestText = ReleaseCheckout.strippingComments(
            try String(contentsOf: packageManifest, encoding: .utf8)
        )
        #expect(!manifestText.contains("\"DefAIkeShareExtension\""))
        #expect(manifestText.contains("name: \"DefAIkeShareExtensionKit\""))
        let occurrences = manifestText.components(separatedBy: "DefAIkeShareExtension").count - 1
        #expect(occurrences == 1, "the only mention must be the composition product")
    }

    @Test("The main application's provisioning gap vocabulary is also outside this package")
    func theProvisioningVocabularyIsOutsideThisPackage() throws {
        // 12.1's eleven owed inputs, 12.2's six extension additions, 12.3's linked-versus-
        // provisioned adapter check, and 12.1's `AdmittedMainApp` all live beside the Xcode
        // app target. `AbsentPolicyArtifactStore` in this file reproduces the *behaviour* of the
        // load-bearing one; the enumeration itself is unreachable and is recorded here so the
        // gap is not mistaken for coverage.
        let root = try #require(ReleaseCheckout.iosRoot)
        let provisioning = root.appending(
            path: "DefAIkeApp/Shared/MainAppReleaseProvisioning.swift"
        )
        #expect(FileManager.default.fileExists(atPath: provisioning.path))
        #expect(!provisioning.path.contains("/DefAIkePackage/"))
        let code = ReleaseCheckout.strippingComments(
            try String(contentsOf: provisioning, encoding: .utf8)
        )
        #expect(code.contains("enum UnprovisionedReleaseInput"))
        #expect(code.contains("struct UnprovisionedPolicyArtifactStore: PolicyArtifactReading"))
        // Its refusal is the same one this file's local store reports, which is what makes the
        // behavioural substitution honest.
        #expect(code.contains("throw .storeUnavailable"))
    }

    @Test("ParityRunBinding is in a module this test target does not depend on")
    func parityRunBindingIsOutOfReach() throws {
        // The remaining mixed-version finding this task names — `ParityRunBinding` never
        // reconciling `capabilityImplementationVersions` — is in `DefAIkeReleaseValidation`,
        // which `DefAIkeApplicationTests` does not link, and 12.4's manifest note forbids
        // adding a dependency edge. Recorded rather than covered.
        let root = try #require(ReleaseCheckout.iosRoot)
        let parity = root.appending(
            path: "DefAIkePackage/Sources/DefAIkeReleaseValidation/ParityValidation.swift"
        )
        #expect(FileManager.default.fileExists(atPath: parity.path))
        let manifestText = ReleaseCheckout.strippingComments(
            try String(
                contentsOf: root.appending(path: "DefAIkePackage/Package.swift"),
                encoding: .utf8
            )
        )
        // The one test target that links it is not this one.
        #expect(manifestText.contains("name: \"DefAIkeReleaseValidationTests\""))
    }
}
