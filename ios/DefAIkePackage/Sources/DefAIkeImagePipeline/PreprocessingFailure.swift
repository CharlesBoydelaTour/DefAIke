import DefAIkeDomain

// Why preprocessing did not produce a working-space RGB image.
//
// Requirement 3.11 admits exactly one outcome when the bound contract cannot be applied
// to an accepted decoded input: `preprocessing-error`, with no pixel inference. There is
// no partial result, no warning, and no second attempt with a different action. This
// enum is that rule written as a type — every contract-related case maps to that one
// category, and there is deliberately no case meaning "approximated", "substituted a
// nearby color space", or "guessed the orientation", because no code path in this module
// does any of those.
//
// Two cases are not contract failures and do not map to `preprocessing-error`:
//
//   * ``resourceBreach(_:)`` is the active Resource Budget refusing an allocation the
//     transform needs. Requirement 3.4 gives that its own category, and the design's
//     state machine has a separate resource edge out of the preparing state.
//   * ``cancelled`` is the user. It is never an Analysis Error and must never be
//     presented as one (Requirements 11.14 and 15.7).
//
// Keeping all three in one vocabulary means the mapping to ``AnalysisFault`` happens in
// exactly one place, so no stage of the transform can classify its own failure
// differently from the others.

/// Why preprocessing did not produce its result.
enum PreprocessingFailure: Hashable, Sendable, Error {
    /// A contract rule map does not bind all four metadata states exactly once.
    case metadataRuleNotTotal(field: String)

    /// The contract's action for the observed state is to refuse the input.
    ///
    /// Not a defect: ``OrientationAction/rejectAsPreprocessingError`` and its siblings
    /// exist so a release can refuse a metadata state rather than guess at it, so this
    /// case is the contract being applied exactly.
    case actionRejectsObservedState(field: String, state: ImageMetadataState)

    /// The contract binds "apply the declared orientation" to a state that carries no
    /// single declared orientation.
    ///
    /// Absent, malformed, and unsupported orientation metadata name no transform. A
    /// contract that asks for the declared orientation in one of those states is asking
    /// for something that does not exist, and treating it as the identity transform
    /// would be the implicit fallback Requirement 3.8 forbids — silently analyzing a
    /// sideways image as though it were upright.
    case declaredOrientationUnavailable(state: ImageMetadataState)

    /// The contract names a working color space this build cannot resolve.
    case workingColorSpaceUnavailable(identifier: String)

    /// The contract's working color space resolved, but not to a three-channel RGB
    /// space.
    case workingColorSpaceNotThreeChannelRGB(identifier: String)

    /// The contract binds the working space to exact ICC bytes the resolved space does
    /// not carry.
    case workingColorSpaceProfileMismatch(identifier: String)

    /// The decoded image's samples cannot be relabelled as working-space samples
    /// without the color conversion the bound action forbids.
    case sourceSamplesNotAssignable(reason: String)

    /// A framework operation the bound action requires did not succeed.
    ///
    /// `code` is the `vImage_Error` or Core Graphics status, kept for diagnosis only. It
    /// never reaches a user-facing surface: the closed `AnalysisError` vocabulary has no
    /// place for a framework code, which is the point of the vocabulary.
    case frameworkOperationFailed(operation: String, code: Int)

    /// A buffer the transform needs could not be allocated, or its size is not
    /// representable.
    case bufferUnavailable(width: Int, height: Int, channelCount: Int)

    /// The transform produced dimensions that disagree with the bound orientation's
    /// declared geometry.
    ///
    /// Unreachable while the orientation step table and its axis-exchange rule agree. It
    /// exists because the two are stated separately on purpose, and a disagreement would
    /// otherwise hand a transposed image to the resize step where nothing would notice.
    case orientedGeometryMismatch(expected: PixelDimensions, produced: PixelDimensions)

    /// The resized dimensions the bound contract asks for cannot be computed exactly.
    ///
    /// The scaled long edge is `longEdge * targetShortEdge / shortEdge`, and a product
    /// that does not fit in an `Int` has no exact integer answer. A wrapped product would
    /// name a small, plausible, and entirely wrong target size, so it is refused instead.
    case resizeGeometryNotRepresentable(source: PixelDimensions, targetShortEdge: Int)

    /// The resized image's short edge is not exactly the contract's target.
    ///
    /// Unreachable while the target is assigned to the short axis and the long edge is
    /// derived from a ratio of at least one. It exists because Requirement 4.4 says
    /// *equals* rather than *approximately*, and the two statements of that — the
    /// assignment and this check — are deliberately independent.
    case resizedShortEdgeMismatch(expected: Int, produced: Int)

    /// The contract's crop does not lie wholly inside the resized image.
    ///
    /// With the short edge at 440 and the crop at 384 the difference is always
    /// non-negative, so this is the structural check that the two contract fields agree
    /// rather than an expected outcome. Clipping the crop instead would hand the model a
    /// buffer smaller than the shape it declares.
    case cropNotWithinResizedImage(crop: PixelDimensions, resized: PixelDimensions)

    /// A source coordinate or its interpolation weights are not representable.
    ///
    /// The exact rational mapping from a destination index to a source coordinate needs
    /// products of the two extents, and the interpolation needs the product of the two
    /// axis denominators. Neither is allowed to wrap: a wrapped weight produces a sample
    /// that is in range and wrong, which no later stage can detect.
    case sampleCoordinateNotRepresentable(sourceExtent: Int, destinationExtent: Int)

    /// The bound contract's geometry is not one this build can apply at all.
    ///
    /// Distinct from a value that cannot be represented: this is a contract whose fields
    /// describe something other than a positive crop taken from a resized image.
    case contractGeometryNotApplicable(reason: String)

    /// The prepared buffer is not the unsigned 8-bit three-channel RGB the bound model
    /// input requires.
    ///
    /// Requirements 4.6 through 4.8 put the shape, the element type, the channel order,
    /// and the absence of app-side normalization in the contract, and the schema already
    /// refuses a contract that disagrees with them. This case is the adapter refusing to
    /// hand over a buffer that disagrees with the contract it was produced under — a
    /// padded row, a channel count that is not three, a byte count that is not
    /// `edge * edge * 3`. Producing it anyway would be measured as parity.
    case modelInputNotProducible(reason: String)

    /// The active Resource Budget refuses an allocation the transform needs.
    case resourceBreach(ValidationResourceChecks.Breach)

    /// The user cancelled.
    case cancelled

    /// The fault this failure raises.
    ///
    /// The single mapping site. Every contract-related case is `preprocessing-error` at
    /// the preprocessing stage; a budget refusal keeps `resource-limit`; cancellation
    /// stays outside the Analysis Error vocabulary entirely.
    var fault: AnalysisFault {
        switch self {
        case .cancelled:
            .cancelled
        case .resourceBreach(let breach):
            breach.fault(at: .preprocessing)
        case .metadataRuleNotTotal,
             .actionRejectsObservedState,
             .declaredOrientationUnavailable,
             .workingColorSpaceUnavailable,
             .workingColorSpaceNotThreeChannelRGB,
             .workingColorSpaceProfileMismatch,
             .sourceSamplesNotAssignable,
             .frameworkOperationFailed,
             .bufferUnavailable,
             .orientedGeometryMismatch,
             .resizeGeometryNotRepresentable,
             .resizedShortEdgeMismatch,
             .cropNotWithinResizedImage,
             .sampleCoordinateNotRepresentable,
             .contractGeometryNotApplicable,
             .modelInputNotProducible:
            .analysis(.preprocessingError, stage: .preprocessing)
        }
    }
}
