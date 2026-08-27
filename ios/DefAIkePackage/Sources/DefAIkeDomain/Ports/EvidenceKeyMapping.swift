// The one-to-one mapping between runtime evidence values and encoded artifact keys.
//
// `Sources/DefAIkeDomain/ReleaseArtifacts/EvidenceSchemaKeys.swift` deliberately
// keeps the signed-JSON key vocabulary separate from the evidence-carrying core
// values, and left the exhaustive mapping between them to "one place" in a later
// task. This is that place.
//
// Every mapping here is total and injective, and each is written as an exhaustive
// `switch` with no `default`, so adding a case to either side is a compile error
// rather than a silent fallthrough. Fusion lookup, fixture comparison, and copy
// resolution all go through these members instead of comparing raw strings.
//
// The asymmetry is intentional and load-bearing:
//
//   * ``PixelEvidence`` maps both ways: three labels, three keys.
//   * ``ProvenanceCategory`` maps both ways: five enabled states, five keys. The
//     unavailable lane has no key at all, which is why an unavailable lane cannot be
//     looked up in a fusion table (Requirements 6.9, 6.21, and 7.10).
//   * ``AnalysisError`` maps both ways over all ten categories.

// MARK: - Pixel labels

extension PixelEvidence {
    /// The encoded key a signed artifact uses for this label.
    public var labelKey: PixelLabelKey {
        switch self {
        case .signalsConsistentWithAIGeneration: .signalsConsistentWithAIGeneration
        case .noStrongSignalDetected: .noStrongSignalDetected
        case .notEnoughSignal: .notEnoughSignal
        }
    }

    /// The release metric category this label contributes to (Requirement 5.3).
    ///
    /// Insufficient outcomes stay in the false-positive and true-positive
    /// denominators, so abstention is a category rather than an exclusion.
    public var metricCategory: PixelMetricCategory { labelKey.requiredMetricCategory }
}

extension PixelLabelKey {
    /// The runtime evidence value this key names.
    public var pixelEvidence: PixelEvidence {
        switch self {
        case .signalsConsistentWithAIGeneration: .signalsConsistentWithAIGeneration
        case .noStrongSignalDetected: .noStrongSignalDetected
        case .notEnoughSignal: .notEnoughSignal
        }
    }
}

// MARK: - Provenance states

extension ProvenanceCategory {
    /// The encoded key a signed artifact uses for this enabled state.
    public var stateKey: ProvenanceStateKey {
        switch self {
        case .validated: .validated
        case .invalid: .invalid
        case .absent: .absent
        case .unsupported: .unsupported
        case .indeterminate: .indeterminate
        }
    }
}

extension ProvenanceStateKey {
    /// The enabled runtime category this key names.
    public var provenanceCategory: ProvenanceCategory {
        switch self {
        case .validated: .validated
        case .invalid: .invalid
        case .absent: .absent
        case .unsupported: .unsupported
        case .indeterminate: .indeterminate
        }
    }
}

extension ProvenanceEvidence {
    /// The encoded key for this enabled state.
    public var stateKey: ProvenanceStateKey { category.stateKey }
}

extension ProvenanceLane {
    /// The encoded key for this lane, or `nil` when the lane is unavailable.
    ///
    /// `nil` is the structural fusion bypass: with no key there is no table entry to
    /// look up, so an unavailable lane always omits the Combined Summary.
    public var stateKey: ProvenanceStateKey? { category?.stateKey }
}

// MARK: - Fusion keys

extension FusionLaneCombination {
    /// The table key for one pixel label and one enabled provenance value.
    ///
    /// A named factory rather than an initializer overload. ``PixelEvidence`` and
    /// ``PixelLabelKey`` share case names, as do ``ProvenanceEvidence`` and
    /// ``ProvenanceStateKey``, so an overloaded `init(pixel:provenance:)` would make
    /// every existing leading-dot call site ambiguous. Converting a category instead is
    /// one explicit step: `FusionLaneCombination(pixel: label.labelKey, provenance:
    /// category.stateKey)`.
    public static func lookupKey(
        pixel: PixelEvidence,
        provenance: ProvenanceEvidence
    ) -> FusionLaneCombination {
        FusionLaneCombination(pixel: pixel.labelKey, provenance: provenance.stateKey)
    }
}

// MARK: - Byte preservation status

extension BytePreservationStatus {
    /// The encoded key a fixture or ticket uses for this status.
    public var statusKey: BytePreservationStatusKey {
        switch self {
        case .originalBytes: .originalBytes
        case .platformTransformedCopy: .platformTransformedCopy
        case .unknown: .unknown
        }
    }
}

extension BytePreservationStatusKey {
    /// The runtime status this key names.
    public var preservationStatus: BytePreservationStatus {
        switch self {
        case .originalBytes: .originalBytes
        case .platformTransformedCopy: .platformTransformedCopy
        case .unknown: .unknown
        }
    }
}

// MARK: - Analysis errors

extension AnalysisError {
    /// The encoded key a fixture uses to declare this expected error.
    public var errorKey: AnalysisErrorKey {
        switch self {
        case .unsupportedMedia: .unsupportedMedia
        case .unsupportedStaticFormat: .unsupportedStaticFormat
        case .decodingError: .decodingError
        case .resourceLimit: .resourceLimit
        case .preprocessingError: .preprocessingError
        case .modelLoadError: .modelLoadError
        case .inferenceError: .inferenceError
        case .invalidOutputError: .invalidOutputError
        case .calibrationInputError: .calibrationInputError
        case .handoffError: .handoffError
        }
    }
}

extension AnalysisErrorKey {
    /// The runtime error category this key names.
    public var analysisError: AnalysisError {
        switch self {
        case .unsupportedMedia: .unsupportedMedia
        case .unsupportedStaticFormat: .unsupportedStaticFormat
        case .decodingError: .decodingError
        case .resourceLimit: .resourceLimit
        case .preprocessingError: .preprocessingError
        case .modelLoadError: .modelLoadError
        case .inferenceError: .inferenceError
        case .invalidOutputError: .invalidOutputError
        case .calibrationInputError: .calibrationInputError
        case .handoffError: .handoffError
        }
    }
}
