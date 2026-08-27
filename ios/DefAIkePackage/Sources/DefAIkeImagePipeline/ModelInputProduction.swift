import DefAIkeDomain

// Step 6: the crop's bytes, and nothing done to them.
//
// Requirements 4.6 through 4.8 split one decision three ways, and the split is the whole
// point: the application hands over unsigned 8-bit RGB, and the model graph scales by
// `1/255` and normalizes with means `(0.485, 0.456, 0.406)` and standard deviations
// `(0.229, 0.224, 0.225)`. If both sides did it the samples would be normalized twice, the
// model would see values it was never trained on, and every parity measurement taken
// against the checkpoint would still pass its own self-consistency checks while being
// meaningless.
//
// So this file contains no arithmetic on a sample value. It copies. The only thing it
// decides is whether the buffer it was handed is the buffer the bound
// ``ModelInputContract`` declares, and it refuses rather than reshapes: no padding is
// stripped by reinterpretation, no channel is dropped or added, no dimension is adjusted.
//
// Separated from ``ContractImagePreprocessor`` for the reason the metadata observation
// rules were separated from the inspector: several of these refusals cannot be produced by
// the adapter's own pipeline — the renderer always returns three tightly packed channels —
// and a branch that is only reachable from a real container is a branch that stays
// unexercised until a user reaches it.

/// Produces the bound model input's bytes from the finished crop.
enum ModelInputProduction {
    /// Channels in the model input buffer.
    ///
    /// Three, which is Requirement 4.6's three-channel RGB. Stated here as well as in the
    /// renderer because this is the count the byte layout is derived from, and a buffer
    /// whose length and channel count disagree would be read at the wrong stride.
    static let channelCount = 3

    /// The crop's bytes, exactly as the crop produced them.
    ///
    /// Throws ``PreprocessingFailure/modelInputNotProducible(reason:)`` when `surface` is
    /// not the square, tightly packed, three-channel buffer `modelInput` declares, or when
    /// `modelInput` itself declares something this build does not produce.
    ///
    /// The contract checks are restated here even though ``ModelInputContract``'s
    /// initializer already proves them. The schema proves a *decoded* contract's
    /// coherence; a contract value can be assembled in process without passing through it,
    /// and the cost of restating four comparisons is nothing next to handing the model a
    /// buffer whose declared shape is not its actual one.
    static func bytes(
        from surface: PixelSurface,
        modelInput: ModelInputContract
    ) throws(PreprocessingFailure) -> [UInt8] {
        guard modelInput.channelOrder == .rgb else {
            throw .modelInputNotProducible(
                reason: "the bound channel order \(modelInput.channelOrder.rawValue) is not RGB"
            )
        }
        guard modelInput.elementType == .uint8 else {
            throw .modelInputNotProducible(
                reason: """
                    the bound element type \(modelInput.elementType.rawValue) is not \
                    unsigned 8-bit
                    """
            )
        }
        guard !modelInput.appliesAppSideNormalization else {
            // There is no code path in this module that scales or normalizes a sample, so
            // a contract asking for it is refused rather than ignored. Ignoring it would
            // leave the signed contract claiming a transform that never happened, and the
            // claim is what release parity is measured against.
            throw .modelInputNotProducible(
                reason: "the bound contract claims app-side normalization, which is never applied"
            )
        }
        guard modelInput.width == modelInput.height else {
            throw .modelInputNotProducible(
                reason: """
                    the bound model input is \(modelInput.width)x\(modelInput.height), \
                    not square
                    """
            )
        }
        let edge = modelInput.width
        guard surface.width == edge, surface.height == edge else {
            throw .modelInputNotProducible(
                reason: """
                    the crop is \(surface.width)x\(surface.height) but the bound model \
                    input is \(edge)x\(edge)
                    """
            )
        }
        guard surface.channelCount == channelCount else {
            throw .modelInputNotProducible(
                reason: "the crop carries \(surface.channelCount) channels, not \(channelCount)"
            )
        }
        guard surface.isTightlyPacked else {
            // A padded stride read as if it were packed shears the image by a few pixels a
            // row. That survives to the model and still looks like a photograph, so it is
            // refused here rather than repacked by a reader that assumed the stride.
            throw .modelInputNotProducible(
                reason: """
                    the crop has \(surface.rowBytes) bytes a row, not \
                    \(edge * channelCount)
                    """
            )
        }
        let bytes = surface.copyPackedBytes()
        guard UInt64(bytes.count) == UInt64(edge) * UInt64(edge) * UInt64(channelCount) else {
            // Unreachable while the surface is tightly packed and square, and stated
            // anyway: this is the length the Core ML adapter reads at a fixed stride.
            throw .modelInputNotProducible(
                reason: "the packed crop is \(bytes.count) bytes, not \(edge * edge * channelCount)"
            )
        }
        return bytes
    }
}
