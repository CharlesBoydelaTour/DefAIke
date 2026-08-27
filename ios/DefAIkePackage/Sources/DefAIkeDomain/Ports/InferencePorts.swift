// The inference and calibration ports.
//
// The Core ML adapter lives in `DefAIkeCoreML`; calibration is a pure total function
// in the domain. Neither signature mentions `MLModel`, `MLFeatureProvider`, or
// `MLMultiArray`, so output-validation and calibration properties run over generated
// logits and quality records without loading a model (Properties 14 and 16).

/// One finite raw logit from the pixel model.
///
/// Non-finite is not representable. Requirement 4.15 makes a missing, misnamed,
/// nonscalar, nonnumeric, or nonfinite output `invalid-output-error`, and Requirement
/// 4.16 forbids mapping it to a pixel label; making NaN and infinity unconstructible
/// here means no calibration path can receive one, so the check cannot be forgotten
/// at one call site.
///
/// A logit is not a probability, confidence, or score, and it never reaches a report
/// unless an approved optional-detail artifact enables it and labels it uncalibrated
/// (Requirements 8.9 and 8.13).
public struct RawLogit: Hashable, Sendable, CustomStringConvertible {
    /// The finite, positive-going raw value: larger means more evidence of synthesis.
    public let value: Double

    /// Creates a logit, or `nil` when `value` is NaN or infinite.
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.value = value
    }

    /// Deliberately does not spell the value, so a logit cannot be logged as an
    /// image-derived value (Requirement 9.11). Diagnostics that legitimately need the
    /// number read ``value`` explicitly.
    public var description: String { "RawLogit(finite)" }
}

/// The loaded Core ML model one session is bound to.
///
/// Carries the identity and schema the adapter verified at load: the bundle it came
/// from, the exact checkpoint and weight digest, the Core ML component version, and
/// the input and output contracts the runtime feature schema was checked against. A
/// later activation or rollback cannot change it, because a session holds this value
/// rather than re-reading the active pointer (Requirements 4.1, 10.14, and 10.18).
public struct BoundCoreMLModel: Hashable, Sendable {
    public let bundleID: ModelBundleID
    public let modelIdentity: ModelIdentity
    public let coreMLModelVersion: ArtifactID
    public let inputContract: ModelInputContract
    public let outputContract: ModelOutputContract

    /// The loaded model instance held by the Core ML adapter.
    public let model: LoadedModelToken

    /// Creates a bound model, or `nil` when the identity is not the sole permitted
    /// pixel model.
    ///
    /// Requirement 1.16 fixes the Lowq checkpoint as the only pixel model for every
    /// route and quality condition, so a loaded model with any other identity is not
    /// representable at this boundary (Property 2).
    public init?(
        bundleID: ModelBundleID,
        modelIdentity: ModelIdentity,
        coreMLModelVersion: ArtifactID,
        inputContract: ModelInputContract,
        outputContract: ModelOutputContract,
        model: LoadedModelToken
    ) {
        guard modelIdentity == RequiredPixelModel.identity else { return nil }
        self.bundleID = bundleID
        self.modelIdentity = modelIdentity
        self.coreMLModelVersion = coreMLModelVersion
        self.inputContract = inputContract
        self.outputContract = outputContract
        self.model = model
    }

    /// Whether `input` matches the shape this model was loaded against.
    public func accepts(_ input: ModelImageInput) -> Bool {
        input.edge == inputContract.width
            && input.edge == inputContract.height
            && input.channelOrder == inputContract.channelOrder
            && input.elementType == inputContract.elementType
    }
}

/// Loads the bound model with a configuration that permits Apple Neural Engine
/// execution.
///
/// Load failure, an incompatible generated model description, and a failed required
/// self-test are all `.analysis(.modelLoadError, stage: .modelLoad)`. The adapter never
/// falls through to an older or unverified asset (Requirements 4.14 and 10.19).
public protocol PixelModelLoading: Sendable {
    func loadModel(
        from bundle: BoundModelBundle
    ) async throws(AnalysisFault) -> BoundCoreMLModel
}

/// Runs one asynchronous prediction and validates the runtime feature result.
///
/// Exactly one outcome: one finite ``RawLogit``, or one fault. Execution failure after
/// a valid input is `inference-error`; a missing, misnamed, nonscalar, nonnumeric, NaN,
/// or infinite output is `invalid-output-error`. Neither produces Pixel Evidence
/// (Requirements 4.9 through 4.11, 4.15, and 4.16).
public protocol PixelAnalyzing: Sendable {
    func infer(
        _ input: ModelImageInput,
        model: BoundCoreMLModel
    ) async throws(AnalysisFault) -> RawLogit
}

/// Maps one finite logit and one validated quality record to exactly one pixel label.
///
/// Pure, total, deterministic, and synchronous: the same inputs always give the same
/// label, and the port is not `async` because there is nothing to await and no
/// opportunity for a late callback to change a committed result.
///
/// Total over every finite logit and valid record, with closed abstention bands and
/// the sub-440 rule. A required quality value that is missing or invalid and not
/// covered by an explicit approved abstention rule is
/// `.analysis(.calibrationInputError, stage: .calibration)` with no Pixel Evidence
/// (Requirements 5.4, 5.8 through 5.10, 5.24, and 5.25).
public protocol PixelCalibrating: Sendable {
    func classify(
        _ logit: RawLogit,
        quality: InputQualityRecord,
        policy: CalibrationPolicy
    ) throws(AnalysisFault) -> PixelEvidence
}
