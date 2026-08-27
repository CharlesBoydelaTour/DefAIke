import DefAIkeDomain

// Programmable stubs for the analysis pipeline ports.
//
// Each one records its invocation in the shared ``PortCallRecorder`` before doing anything
// else, so a nonoccurrence assertion is about the call and not about the result, and a
// stub that is programmed to fail still proves it was reached.
//
// None of them decides a policy: a stub returns exactly what the test queued. That keeps
// the doubles free of the unresolved boundaries, budgets, mappings, and contracts that
// remain approved external inputs.

/// Records the import call and returns the queued ingest outcome.
public final class StubPhotosImporter: PhotosImporting, Sendable {
    private let outcome: StubOutcome<ImportedEncodedAsset>
    private let recorder: PortCallRecorder?

    public init(outcome: StubOutcome<ImportedEncodedAsset>, recorder: PortCallRecorder? = nil) {
        self.outcome = outcome
        self.recorder = recorder
    }

    /// A stub whose provider always fails before any byte is held, which is a
    /// no-session ingest outcome rather than a user-facing evidence error.
    public static func alwaysFailingProvider(
        recorder: PortCallRecorder? = nil
    ) -> StubPhotosImporter {
        StubPhotosImporter(
            outcome: StubOutcome(
                alwaysFailing: .analysis(.decodingError, stage: .mediaClassification)
            ),
            recorder: recorder
        )
    }

    public func importOne(
        _ item: PhotosPickerItemReference,
        into sessionID: AnalysisSessionID
    ) async throws(AnalysisFault) -> ImportedEncodedAsset {
        recorder?.record(.photosImport(sessionID))
        return try outcome.resolve()
    }
}

/// Records the validation call and returns the queued outcome.
///
/// The workhorse of the short-circuit properties: programming it with
/// `.analysis(.unsupportedMedia, stage: .mediaClassification)` and then asserting that the
/// recorder saw no `preprocess`, `infer`, `calibrate`, `provenanceAnalyze`, or `fuse` call
/// is exactly Property 3.
public final class StubInputValidator: InputValidating, Sendable {
    private let outcome: StubOutcome<ValidatedImage>
    private let recorder: PortCallRecorder?

    /// Contract and budget the stub was called with, for argument assertions.
    private let received = LockedBox<[(contract: ArtifactID, budget: ArtifactID)]>([])

    public init(outcome: StubOutcome<ValidatedImage>, recorder: PortCallRecorder? = nil) {
        self.outcome = outcome
        self.recorder = recorder
    }

    /// Artifact versions the stub was invoked with, in order.
    ///
    /// Lets a test check that a session used the versions it was *bound* to rather than
    /// whatever became active later (Property 13).
    public var receivedArtifactVersions: [(contract: ArtifactID, budget: ArtifactID)] {
        received.value
    }

    public func validate(
        _ asset: ImportedEncodedAsset,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ValidatedImage {
        recorder?.record(.validate(asset.sessionID))
        received.withValue { $0.append((contract: contract.id, budget: budget.id)) }
        return try outcome.resolve()
    }
}

/// Records the preprocessing call and returns the queued outcome.
public final class StubImagePreprocessor: ImagePreprocessing, Sendable {
    private let outcome: StubOutcome<ModelImageInput>
    private let recorder: PortCallRecorder?

    public init(outcome: StubOutcome<ModelImageInput>, recorder: PortCallRecorder? = nil) {
        self.outcome = outcome
        self.recorder = recorder
    }

    /// A stub that can never apply the bound contract. There is no fallback path, so
    /// `preprocessing-error` is the only outcome.
    public static func alwaysFailing(
        recorder: PortCallRecorder? = nil
    ) -> StubImagePreprocessor {
        StubImagePreprocessor(
            outcome: StubOutcome(
                alwaysFailing: .analysis(.preprocessingError, stage: .preprocessing)
            ),
            recorder: recorder
        )
    }

    public func prepare(
        _ image: ValidatedImage,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ModelImageInput {
        recorder?.record(.preprocess(image.sessionID))
        return try outcome.resolve()
    }
}

/// Records the model-load call and returns the queued outcome.
public final class StubPixelModelLoader: PixelModelLoading, Sendable {
    private let outcome: StubOutcome<BoundCoreMLModel>
    private let recorder: PortCallRecorder?

    public init(outcome: StubOutcome<BoundCoreMLModel>, recorder: PortCallRecorder? = nil) {
        self.outcome = outcome
        self.recorder = recorder
    }

    public func loadModel(
        from bundle: BoundModelBundle
    ) async throws(AnalysisFault) -> BoundCoreMLModel {
        recorder?.record(.loadModel(bundle.bundleID))
        return try outcome.resolve()
    }
}

/// Records the inference call and returns the queued logit or fault.
///
/// A non-finite model output cannot be programmed as a success, because ``RawLogit``
/// cannot hold one. NaN and infinity are reached through
/// `.analysis(.invalidOutputError, stage: .outputValidation)`, which is the only outcome
/// the requirements allow for them.
public final class StubPixelAnalyzer: PixelAnalyzing, Sendable {
    private let outcome: StubOutcome<RawLogit>
    private let recorder: PortCallRecorder?

    public init(outcome: StubOutcome<RawLogit>, recorder: PortCallRecorder? = nil) {
        self.outcome = outcome
        self.recorder = recorder
    }

    /// A stub returning one finite logit for every call.
    ///
    /// Traps on a non-finite `value`: a test that means "the model emitted NaN" must
    /// program `invalidOutputError` instead, because a NaN success is unrepresentable.
    public static func returning(
        logit value: Double,
        recorder: PortCallRecorder? = nil
    ) -> StubPixelAnalyzer {
        guard let logit = RawLogit(value) else {
            preconditionFailure(
                "a non-finite model output is invalid-output-error, not a RawLogit"
            )
        }
        return StubPixelAnalyzer(outcome: StubOutcome(always: logit), recorder: recorder)
    }

    public func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit {
        recorder?.record(.infer(input.sessionID))
        return try outcome.resolve()
    }
}

/// Records the calibration call and returns the queued label or fault.
///
/// Synchronous, matching the port: calibration is a pure total function, and giving the
/// double an `await` would invent a suspension point where a late result could arrive.
public final class StubPixelCalibrator: PixelCalibrating, Sendable {
    private let outcome: StubOutcome<PixelEvidence>
    private let recorder: PortCallRecorder?

    public init(outcome: StubOutcome<PixelEvidence>, recorder: PortCallRecorder? = nil) {
        self.outcome = outcome
        self.recorder = recorder
    }

    public static func returning(
        _ evidence: PixelEvidence,
        recorder: PortCallRecorder? = nil
    ) -> StubPixelCalibrator {
        StubPixelCalibrator(outcome: StubOutcome(always: evidence), recorder: recorder)
    }

    public func classify(
        _ logit: RawLogit,
        quality: InputQualityRecord,
        policy: CalibrationPolicy
    ) throws(AnalysisFault) -> PixelEvidence {
        recorder?.record(.calibrate)
        return try outcome.resolve()
    }
}
