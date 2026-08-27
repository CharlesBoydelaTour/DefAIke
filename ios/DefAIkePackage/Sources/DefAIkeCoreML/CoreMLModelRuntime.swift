import DefAIkeDomain
import CoreML
import CoreVideo
import Foundation

// The only file in this module that imports Core ML.
//
// Everything above it is a value, a pure check, or an actor holding one, so the
// requirement mapping is testable without a compiled model. This file is the part that
// cannot be: it loads a real `MLModel`, builds a real pixel buffer, runs a real
// asynchronous prediction, and projects the framework's description and result into the
// seam's values.
//
// What the configuration below does and does not establish, stated once so no comment
// or diagnostic downstream over-claims it: setting ``MLComputeUnits/all`` *permits*
// Apple Neural Engine execution, which is what Requirement 4.11 asks for. Core ML
// exposes no API that reports where a model actually executed, and none that reports
// latency, memory, energy, or thermal behavior. Those remain physical-device
// measurements under the approved Device Validation Plan (Requirement 13.13 and the
// design's platform-mechanism notes), and nothing in this file may be read as evidence
// for them.
//
// Inference is entirely local: a compiled model already on the device, a buffer already
// in memory, and no URL session, no server, and no discovery member anywhere in the
// path (Requirements 4.10 and 10.21).

// MARK: - Locating the compiled model

/// Where the compiled Core ML model for a verified Model Bundle lives on this device.
///
/// This module deliberately cannot answer that question: resolving a verified bundle to
/// a directory is the Model Bundle layer's job, because that layer is what verified the
/// manifest, the declared artifact paths, and their digests. Keeping the answer outside
/// means the analyzer has no default path, no search order, and no way to load an asset
/// the bundle does not name.
///
/// `nil` is a fail-closed refusal, never a reason to look elsewhere.
public protocol CompiledPixelModelLocating: Sendable {
    func compiledModelLocation(for bundle: BoundModelBundle) -> URL?
}

// MARK: - Loading

/// Loads a compiled Core ML model with a configuration that permits Apple Neural
/// Engine execution.
public struct CoreMLModelRuntimeLoader: PixelModelRuntimeLoading {
    private let locations: any CompiledPixelModelLocating

    public init(locations: any CompiledPixelModelLocating) {
        self.locations = locations
    }

    public func loadRuntime(
        for bundle: BoundModelBundle
    ) async throws(ModelRuntimeLoadFault) -> any PixelModelRuntime {
        guard let location = locations.compiledModelLocation(for: bundle) else {
            throw .compiledModelUnavailable
        }
        do {
            return try await CoreMLModelRuntime.load(compiledModelAt: location)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            // Every Core ML load failure is one fault. The framework error is not
            // wrapped and not carried further: the caller maps this to
            // `model-load-error`, and a framework message is not presentable.
            throw .frameworkRefusedLoad
        }
    }
}

// MARK: - One loaded model

/// One loaded `MLModel`, narrowed to a schema and one asynchronous prediction.
///
/// `MLModel` is not `Sendable`, so holding one behind a `Sendable` protocol has to say
/// where the safety comes from. Two facts, both checkable:
///
///   * This type has no mutable state. Both stored properties are `let`: an immutable
///     model reference and the schema value read from it at load. Nothing here can be
///     changed by one caller while another reads it.
///   * The prediction path is stateless. Core ML's own documented serialization
///     requirement is for stateful predictions that share an `MLState`, and this model
///     uses none, so no member of this type creates, holds, or passes state. A future
///     model that did carry state would need explicit serialization added here.
///
/// An actor was the obvious alternative and would be misleading: actors are reentrant
/// across `await`, so isolating the instance would not actually serialize the
/// predictions, only make it look like it did.
public final class CoreMLModelRuntime: PixelModelRuntime, @unchecked Sendable {
    /// The description read once at load, never re-read, so the schema the loader
    /// validated against the bound contracts is the schema every prediction is checked
    /// against.
    public let schema: RuntimeModelSchema

    private let model: MLModel

    private init(model: MLModel, schema: RuntimeModelSchema) {
        self.model = model
        self.schema = schema
    }

    /// Loads the compiled model at `location`.
    ///
    /// `MLComputeUnits.all` is the whole of Requirement 4.11's "permit Apple Neural
    /// Engine execution": it allows Core ML to use the CPU, the GPU, and the Neural
    /// Engine. It does not select, request, or confirm any of them.
    public static func load(compiledModelAt location: URL) async throws -> CoreMLModelRuntime {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try await MLModel.load(contentsOf: location, configuration: configuration)
        return CoreMLModelRuntime(model: model, schema: schema(of: model.modelDescription))
    }

    public func predict(
        _ pixels: PreparedPixelData
    ) async throws(ModelPredictionFault) -> RuntimeFeatureResult {
        guard let input = Self.imageInput(in: schema),
              input.width == pixels.edge,
              input.height == pixels.edge,
              let buffer = Self.pixelBuffer(from: pixels, format: input.pixelFormat)
        else {
            // Unreachable on the shipping path: the loader validated this description
            // against the bound contracts before the model became reachable, so the
            // input is one 384x384 three-channel image feature in a format this build
            // can build. Kept as a fail-closed branch rather than a force-unwrap,
            // because the alternative to a fault here is a crash.
            throw .executionFailed
        }
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                input.name: MLFeatureValue(pixelBuffer: buffer)
            ])
            return Self.project(try await model.prediction(from: provider))
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .executionFailed
        }
    }

    // MARK: - Projecting the generated description

    /// The declared image input this runtime feeds.
    struct ImageInput: Hashable, Sendable {
        let name: String
        let width: Int
        let height: Int
        let pixelFormat: RuntimeImagePixelFormat
    }

    /// The one image input in `schema`, or `nil` when it does not declare exactly one.
    static func imageInput(in schema: RuntimeModelSchema) -> ImageInput? {
        guard schema.inputs.count == 1, let input = schema.inputs.first,
              case .image(let width, let height, let pixelFormat) = input.kind
        else {
            return nil
        }
        return ImageInput(
            name: input.name,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }

    static func schema(of description: MLModelDescription) -> RuntimeModelSchema {
        RuntimeModelSchema(
            inputs: features(in: description.inputDescriptionsByName),
            outputs: features(in: description.outputDescriptionsByName)
        )
    }

    /// Sorted by name so a schema value is stable regardless of dictionary ordering.
    static func features(
        in descriptions: [String: MLFeatureDescription]
    ) -> [RuntimeFeatureDescription] {
        descriptions
            .sorted { $0.key < $1.key }
            .map { RuntimeFeatureDescription(name: $0.key, kind: kind(of: $0.value)) }
    }

    /// What one generated feature description promises.
    ///
    /// The `default` branches are load-bearing across SDK revisions: a feature or
    /// element type this build does not name becomes ``RuntimeFeatureKind/unsupported``
    /// or ``RuntimeElementType/other``, both of which the schema check refuses. A new
    /// framework case therefore fails closed instead of being guessed at.
    static func kind(of description: MLFeatureDescription) -> RuntimeFeatureKind {
        switch description.type {
        case .image:
            guard let constraint = description.imageConstraint else { return .unsupported }
            return .image(
                width: constraint.pixelsWide,
                height: constraint.pixelsHigh,
                pixelFormat: pixelFormat(constraint.pixelFormatType)
            )
        case .multiArray:
            guard let constraint = description.multiArrayConstraint else { return .unsupported }
            // The declared shape, which for one scalar is either an empty shape or a
            // single dimension of one; both multiply out to one element. A model whose
            // real output shape disagrees with its declared shape is caught anyway by
            // the element count of the actual result at every inference.
            let elementCount = constraint.shape.reduce(1) { $0 * $1.intValue }
            return .tensor(elementCount: elementCount, element: element(constraint.dataType))
        case .double:
            return .scalar(.float64)
        case .int64:
            return .scalar(.int64)
        default:
            return .unsupported
        }
    }

    static func element(_ dataType: MLMultiArrayDataType) -> RuntimeElementType {
        switch dataType {
        case .double: .float64
        case .float32: .float32
        case .float16: .float16
        case .int32: .int32
        default: .other
        }
    }

    static func pixelFormat(_ type: OSType) -> RuntimeImagePixelFormat {
        switch type {
        case kCVPixelFormatType_32BGRA: .bgra8
        case kCVPixelFormatType_32ARGB: .argb8
        case kCVPixelFormatType_OneComponent8: .grayscale8
        default: .other
        }
    }

    // MARK: - Projecting one prediction's result

    static func project(_ provider: any MLFeatureProvider) -> RuntimeFeatureResult {
        var features: [String: RuntimeFeatureValue] = [:]
        for name in provider.featureNames {
            // A declared name with no value is left out, so it reads as the missing
            // feature it is rather than as some substituted default.
            guard let value = provider.featureValue(for: name) else { continue }
            features[name] = project(value)
        }
        return RuntimeFeatureResult(features)
    }

    /// One feature value, as one of the three distinctions the output check needs.
    ///
    /// NaN and infinity are carried through as ``RuntimeFeatureValue/scalar`` rather
    /// than rejected here: refusing them is ``ModelOutputCheck``'s job, so there is one
    /// place that decides `invalid-output-error` (Requirement 4.16).
    static func project(_ value: MLFeatureValue) -> RuntimeFeatureValue {
        switch value.type {
        case .double:
            return .scalar(value.doubleValue)
        case .int64:
            return .scalar(Double(value.int64Value))
        case .multiArray:
            guard let array = value.multiArrayValue else { return .nonNumeric }
            guard array.count == 1 else { return .nonScalar(elementCount: array.count) }
            return .scalar(array[0].doubleValue)
        default:
            return .nonNumeric
        }
    }

    // MARK: - Building the input buffer

    /// One pixel buffer in the format the description declares, or `nil` when it
    /// cannot be allocated or the format is not one this build can write.
    ///
    /// The alpha byte a four-component packing carries is set opaque. It is not a model
    /// channel: the bound Preprocessing Contract has already resolved alpha, and the
    /// graph reads the three color channels (Requirements 3.11 and 4.6).
    static func pixelBuffer(
        from pixels: PreparedPixelData,
        format: RuntimeImagePixelFormat
    ) -> CVPixelBuffer? {
        let offsets: (red: Int, green: Int, blue: Int, alpha: Int)
        switch format {
        case .bgra8:
            offsets = (red: 2, green: 1, blue: 0, alpha: 3)
        case .argb8:
            offsets = (red: 1, green: 2, blue: 3, alpha: 0)
        case .grayscale8, .other:
            return nil
        }
        // Total over the channel orders a contract can name, so a new order has to
        // decide how its bytes are read instead of inheriting this one.
        let source: (red: Int, green: Int, blue: Int)
        switch pixels.channelOrder {
        case .rgb:
            source = (red: 0, green: 1, blue: 2)
        }

        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            pixels.edge,
            pixels.edge,
            osType(for: format),
            nil,
            &created
        ) == kCVReturnSuccess, let buffer = created else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let destination = base.assumingMemoryBound(to: UInt8.self)
        // Core Video may pad rows, so the destination row stride is read rather than
        // assumed. The source is tightly packed by ``PreparedPixelData``'s invariant.
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let sourceStride = pixels.edge * 3
        for row in 0..<pixels.edge {
            let sourceRow = row * sourceStride
            let destinationRow = row * destinationStride
            for column in 0..<pixels.edge {
                let read = sourceRow + column * 3
                let write = destinationRow + column * 4
                destination[write + offsets.red] = pixels.bytes[read + source.red]
                destination[write + offsets.green] = pixels.bytes[read + source.green]
                destination[write + offsets.blue] = pixels.bytes[read + source.blue]
                destination[write + offsets.alpha] = .max
            }
        }
        return buffer
    }

    static func osType(for format: RuntimeImagePixelFormat) -> OSType {
        switch format {
        case .bgra8: kCVPixelFormatType_32BGRA
        case .argb8: kCVPixelFormatType_32ARGB
        case .grayscale8: kCVPixelFormatType_OneComponent8
        // Not writable, and never reached: ``pixelBuffer(from:format:)`` refuses an
        // unnamed format before it asks for an allocation type.
        case .other: kCVPixelFormatType_32BGRA
        }
    }
}
