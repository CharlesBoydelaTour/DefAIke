import DefAIkeDomain

// The three things the pixel analyzer reaches out for, and nothing else.
//
// Inference is a decision over three inputs: the compiled model the verified Model
// Bundle names, the prepared 384x384 buffer the Preprocessor produced, and whatever
// the framework hands back. All three arrive through the seams below, so the load,
// execution, and output-validation rules in Requirements 4.14 through 4.16 can be
// exercised without a compiled model and without an iPhone.
//
// No seam here has a default implementation. That is deliberate: a build that has not
// been given a compiled model location cannot load one, instead of searching for a
// file this module chose or falling through to an older asset (Requirement 10.19).
//
// Deliberately absent from every member below: any timeout or deadline; any way to
// report, request, or prove a compute-unit placement, latency, memory, energy, or
// thermal figure; any second model, fallback, or retry-with-different-configuration
// path. Permitting Apple Neural Engine execution is a configuration choice, and no
// Core ML API tells the caller where the model actually ran, so nothing in this
// interface pretends to.

// MARK: - The prepared input

/// The prepared unsigned 8-bit RGB pixels one ``ModelInputToken`` names.
///
/// The image pipeline owns the buffer and the domain carries only its token, so the
/// analyzer resolves the token through ``PreparedPixelResolving`` rather than holding
/// image-derived bytes in a domain value (Requirement 9.1).
///
/// ``bytes`` is tightly packed and row-major with three bytes per pixel in
/// ``channelOrder``: no row padding and no app-side channel scaling or mean and
/// standard-deviation normalization, because both belong to the model graph
/// (Requirements 4.6 through 4.8).
public struct PreparedPixelData: Hashable, Sendable {
    /// Edge length of the square buffer.
    public let edge: Int

    public let channelOrder: ModelChannelOrder

    /// Exactly `edge * edge * 3` bytes.
    public let bytes: [UInt8]

    /// Creates prepared pixels, or `nil` when `bytes` is not exactly one tightly
    /// packed three-channel square of `edge` pixels.
    ///
    /// A short, long, or padded buffer is not representable, so a buffer that is not
    /// the shape it claims cannot reach the framework and be measured as parity.
    public init?(edge: Int, channelOrder: ModelChannelOrder, bytes: [UInt8]) {
        guard edge > 0 else { return nil }
        guard UInt64(bytes.count) == UInt64(edge) * UInt64(edge) * 3 else { return nil }
        self.edge = edge
        self.channelOrder = channelOrder
        self.bytes = bytes
    }
}

/// Resolves the opaque token naming one prepared model input buffer.
///
/// Implemented by whoever owns the buffer, which is the image pipeline adapter in a
/// shipping composition. `nil` is a fail-closed refusal: a token that names nothing
/// resolves to nothing rather than to stale pixels from a session that has ended.
public protocol PreparedPixelResolving: Sendable {
    func preparedPixels(for token: ModelInputToken) async -> PreparedPixelData?
}

// MARK: - The runtime feature schema

/// The pixel format one image feature is declared in.
///
/// Named semantically rather than by framework constant so the schema rules stay
/// readable and testable without Core Video. A format this build does not name is
/// ``other``, which no contract accepts.
public enum RuntimeImagePixelFormat: Hashable, Sendable, CaseIterable {
    /// Interleaved 8-bit blue, green, red, alpha.
    case bgra8
    /// Interleaved 8-bit alpha, red, green, blue.
    case argb8
    /// One 8-bit component.
    case grayscale8
    /// Anything else.
    case other

    /// Whether this format carries three 8-bit color channels.
    ///
    /// The alpha byte a four-component packing carries is not a model channel: the
    /// bound Preprocessing Contract's alpha rule has already resolved alpha before a
    /// buffer reaches here (Requirement 3.11).
    public var carriesThreeColorChannels: Bool {
        switch self {
        case .bgra8, .argb8: true
        case .grayscale8, .other: false
        }
    }
}

/// The element type of one numeric feature.
///
/// A type this build does not name is ``other``, which the output rules refuse. That
/// is fail-closed across SDK revisions: a numeric type added later is not silently
/// accepted as a logit.
public enum RuntimeElementType: Hashable, Sendable, CaseIterable {
    case float16
    case float32
    case float64
    case int32
    case int64
    case other

    public var isFloatingPoint: Bool {
        switch self {
        case .float16, .float32, .float64: true
        case .int32, .int64, .other: false
        }
    }
}

/// What one runtime feature is declared as.
public enum RuntimeFeatureKind: Hashable, Sendable {
    /// An image of exactly these declared pixel dimensions and format.
    case image(width: Int, height: Int, pixelFormat: RuntimeImagePixelFormat)

    /// A numeric tensor holding exactly this many declared elements.
    case tensor(elementCount: Int, element: RuntimeElementType)

    /// One numeric value.
    case scalar(RuntimeElementType)

    /// A feature the bound contracts cannot describe: text, a dictionary, a
    /// sequence, a state, or an invalid description.
    case unsupported
}

/// One named feature in a generated model description.
public struct RuntimeFeatureDescription: Hashable, Sendable {
    public let name: String
    public let kind: RuntimeFeatureKind

    public init(name: String, kind: RuntimeFeatureKind) {
        self.name = name
        self.kind = kind
    }
}

/// The generated model description, projected to the facts the bound contracts fix.
///
/// A projection rather than the framework object, so ``RuntimeSchemaCheck`` is a pure
/// total function over a value a test can build by hand.
public struct RuntimeModelSchema: Hashable, Sendable {
    public let inputs: [RuntimeFeatureDescription]
    public let outputs: [RuntimeFeatureDescription]

    public init(inputs: [RuntimeFeatureDescription], outputs: [RuntimeFeatureDescription]) {
        self.inputs = inputs
        self.outputs = outputs
    }
}

// MARK: - One prediction's result

/// One value in a runtime feature result.
///
/// The three cases are exactly the distinctions Requirement 4.15 and the design draw:
/// one number, a value that is not one number, and a value that is not a number at
/// all. Finiteness is decided by ``ModelOutputCheck`` rather than here, so a nonfinite
/// number stays representable long enough to be refused by name.
///
/// `Hashable` compares the raw `Double`, so two `.scalar` cases holding NaN are not
/// equal to each other. Nothing in this module compares them; the finiteness check
/// runs first.
public enum RuntimeFeatureValue: Hashable, Sendable {
    /// Exactly one number, whichever way the framework spelled it.
    case scalar(Double)

    /// A numeric value that does not hold exactly one element.
    case nonScalar(elementCount: Int)

    /// A value that is not a number: text, an image, a dictionary, a sequence.
    case nonNumeric
}

/// Everything one prediction returned, by feature name.
public struct RuntimeFeatureResult: Hashable, Sendable {
    public let features: [String: RuntimeFeatureValue]

    public init(_ features: [String: RuntimeFeatureValue]) {
        self.features = features
    }
}

// MARK: - Faults the seams report

/// Why a compiled model could not be loaded.
///
/// Every case is `model-load-error` except cancellation, which is a separate terminal
/// outcome and never an Analysis Error (Requirements 4.14 and 11.17). The cases exist
/// so an audit can name which one happened; none of them is a partial success, and
/// there is no case meaning "loaded something else instead".
public enum ModelRuntimeLoadFault: Error, Hashable, Sendable {
    /// This build has no compiled model for that verified bundle.
    case compiledModelUnavailable
    /// Core ML refused the compiled model or the load configuration.
    case frameworkRefusedLoad
    /// The session was cancelled during load.
    case cancelled
}

/// Why one prediction did not return a feature result.
public enum ModelPredictionFault: Error, Hashable, Sendable {
    /// Execution failed after a valid input was supplied (Requirement 4.15).
    case executionFailed
    /// The session was cancelled during execution.
    case cancelled
}

/// One loaded Core ML model, narrowed to what the analyzer needs from it.
///
/// ``schema`` is the description that was read at load and never re-read, so the
/// schema the adapter validated is the schema every prediction is checked against.
public protocol PixelModelRuntime: Sendable {
    var schema: RuntimeModelSchema { get }

    /// Runs one asynchronous prediction over the prepared buffer.
    func predict(
        _ pixels: PreparedPixelData
    ) async throws(ModelPredictionFault) -> RuntimeFeatureResult
}

/// Loads the one compiled model a verified Model Bundle names.
///
/// There is no member that takes a path, a name, a search directory, or a version
/// range: the bundle is the only way to name a model, and an implementation that
/// cannot resolve it fails with ``ModelRuntimeLoadFault/compiledModelUnavailable``.
public protocol PixelModelRuntimeLoading: Sendable {
    func loadRuntime(
        for bundle: BoundModelBundle
    ) async throws(ModelRuntimeLoadFault) -> any PixelModelRuntime
}
