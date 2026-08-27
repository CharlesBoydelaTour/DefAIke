import DefAIkeDomain

// The one thing self-test execution reaches out for: loading a candidate's compiled
// model and running one fixture through it.
//
// Requirement 10.11 requires the *candidate* bundle's own self-tests to run before
// activation, which means executing a model this build has never loaded before. That is
// framework work, and it belongs to the Core ML adapter, so it arrives here through an
// injected seam for the same reason the signature algorithm does: this module decides
// what must be true, never how to make a prediction happen.
//
// Three properties are structural rather than asserted:
//
//   * Offline. No member takes a URL, a host, or a session, and the fixture bytes a
//     runner supplies come only from the candidate's already digest-verified local tree.
//     There is no path by which a self-test reaches the network (Requirements 10.20 and
//     10.21).
//   * No expected results. Nothing in the seam returns, derives, or adjusts an
//     expectation. An executor reports only what it observed; the comparison against the
//     bundle's declared expectations happens in this module, over values the executor
//     cannot see (Requirement 10.9).
//   * No default implementation. A build that has not been given an executor cannot run
//     self-tests, rather than running something this module chose. A candidate whose
//     self-tests did not run is not a candidate that passed.

// MARK: - What an executor is told

/// Everything an executor needs to load and run one candidate, and nothing more.
///
/// Carries no receipt, no activation state, and no pointer: a self-test run cannot
/// observe or change what is currently active.
public struct SelfTestExecutionContext: Hashable, Sendable {
    /// The locally installed candidate being tested. Never the active bundle.
    public let bundleID: ModelBundleID

    /// The compiled Core ML model directory inside that candidate.
    public let compiledModelPath: CanonicalRelativePath

    /// The checkpoint identity and weight digest verification already confirmed.
    public let modelIdentity: ModelIdentity

    /// The candidate's Core ML component version.
    public let coreMLModelVersion: ArtifactID

    /// The input schema the loaded model's description must match.
    public let inputContract: ModelInputContract

    /// The output schema the loaded model's description must match.
    public let outputContract: ModelOutputContract

    /// The candidate's Preprocessing Contract version, so a fixture is prepared the way
    /// the candidate declares rather than the way the active bundle does.
    public let preprocessingContractVersion: ArtifactID

    /// The candidate's Calibration Policy version, for cases that expect a label.
    public let calibrationPolicyVersion: ArtifactID

    public init(
        bundleID: ModelBundleID,
        compiledModelPath: CanonicalRelativePath,
        modelIdentity: ModelIdentity,
        coreMLModelVersion: ArtifactID,
        inputContract: ModelInputContract,
        outputContract: ModelOutputContract,
        preprocessingContractVersion: ArtifactID,
        calibrationPolicyVersion: ArtifactID
    ) {
        self.bundleID = bundleID
        self.compiledModelPath = compiledModelPath
        self.modelIdentity = modelIdentity
        self.coreMLModelVersion = coreMLModelVersion
        self.inputContract = inputContract
        self.outputContract = outputContract
        self.preprocessingContractVersion = preprocessingContractVersion
        self.calibrationPolicyVersion = calibrationPolicyVersion
    }
}

/// One fixture's bytes, as read from the candidate's verified tree.
///
/// The digest travels with the bytes so an executor can confirm it was handed the
/// catalogued asset, and so nothing has to trust a path alone.
public struct SelfTestFixturePayload: Hashable, Sendable {
    public let fixture: FixtureID

    /// Bundle-relative path the bytes were read from.
    public let assetPath: CanonicalRelativePath

    /// The exact catalogued bytes. Already confirmed against the catalogue's digest.
    public let bytes: [UInt8]

    public let contentDigest: SHA256Digest

    public init(
        fixture: FixtureID,
        assetPath: CanonicalRelativePath,
        bytes: [UInt8],
        contentDigest: SHA256Digest
    ) {
        self.fixture = fixture
        self.assetPath = assetPath
        self.bytes = bytes
        self.contentDigest = contentDigest
    }
}

// MARK: - What an executor reports

/// What one self-test case actually produced.
///
/// One optional field per ``SelfTestExpectation`` case, and `nil` means "the run produced
/// nothing for this". It is never read as "matches": a declared expectation with no
/// observation is a missing result, which Requirement 10.10 rejects.
///
/// An executor never reports a comparison outcome. It reports values, and this module
/// compares them, so an executor cannot decide that its own run passed.
public struct SelfTestObservation: Hashable, Sendable {
    /// The raw logit the candidate emitted. Finite by construction.
    public let rawLogit: RawLogit?

    /// The label the candidate's calibration policy produced.
    public let pixelLabel: PixelLabelKey?

    /// Digest of the model-input bytes preprocessing produced.
    public let preprocessingOutputDigest: SHA256Digest?

    /// The Analysis Error the run terminated with, for a case that expects one.
    public let analysisError: AnalysisErrorKey?

    public init(
        rawLogit: RawLogit? = nil,
        pixelLabel: PixelLabelKey? = nil,
        preprocessingOutputDigest: SHA256Digest? = nil,
        analysisError: AnalysisErrorKey? = nil
    ) {
        self.rawLogit = rawLogit
        self.pixelLabel = pixelLabel
        self.preprocessingOutputDigest = preprocessingOutputDigest
        self.analysisError = analysisError
    }

    /// Whether this observation carries a value for `kind`.
    public func carriesValue(for kind: SelfTestExpectationKind) -> Bool {
        switch kind {
        case .rawLogit: rawLogit != nil
        case .pixelLabel: pixelLabel != nil
        case .preprocessingOutputDigest: preprocessingOutputDigest != nil
        case .analysisError: analysisError != nil
        }
    }
}

/// Why an executor could not complete one step.
///
/// Three structural outcomes, no framework error and no user content. Which verification
/// finding each becomes belongs to the runner, not to the executor — and none of them is
/// a pass.
public enum SelfTestExecutionFault: Error, Equatable, Sendable {
    /// The candidate's compiled model could not be loaded.
    case modelLoadFailed
    /// Execution failed after a valid input was prepared.
    case executionFailed
    /// The candidate emitted a missing, misnamed, nonscalar, nonnumeric, or nonfinite
    /// output (Requirement 4.16).
    case invalidOutput
}

// MARK: - The seam

/// Loads a candidate's compiled model and runs its release self-tests offline.
///
/// Deliberately absent: any member that fetches, downloads, resolves, or discovers
/// anything; any member that reads or writes the active bundle pointer; and any member
/// that produces or relaxes an expected result.
public protocol ReleaseSelfTestExecuting: Sendable {
    /// Loads the candidate's model with a configuration that permits Apple Neural Engine
    /// execution, validating the generated model description against the contracts in
    /// `context` (Requirements 4.2, 4.11, and 10.8).
    func loadCandidate(
        _ context: SelfTestExecutionContext
    ) async throws(SelfTestExecutionFault) -> LoadedModelToken

    /// Runs one fixture through the loaded candidate and reports what it produced.
    func run(
        _ payload: SelfTestFixturePayload,
        on model: LoadedModelToken,
        context: SelfTestExecutionContext
    ) async throws(SelfTestExecutionFault) -> SelfTestObservation

    /// Releases the loaded candidate.
    ///
    /// Idempotent and non-failing, so every exit path from a run can unload
    /// unconditionally: a rejected candidate must not stay loaded.
    func unload(_ model: LoadedModelToken) async
}
