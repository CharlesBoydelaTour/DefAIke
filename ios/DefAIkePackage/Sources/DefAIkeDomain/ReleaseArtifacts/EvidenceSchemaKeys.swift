// Closed artifact-schema vocabularies for the evidence values a policy names.
//
// A Calibration Policy names pixel labels, a Provenance Policy and an Evidence
// Fusion Rule name provenance states, a fixture names an expected label, status, or
// error, and an Approved Verdict Copy catalog names all of them. Those are encoded
// artifact keys with canonical kebab-case spellings that live in signed JSON.
//
// The runtime evidence values are separate core domain types. Keeping the encoded
// key vocabulary distinct from the evidence value means artifact wire spelling can
// never drift into an evidence-carrying type, and a fusion table cannot name the
// unavailable provenance lane at all. A later task adds the exhaustive one-to-one
// mapping between the two in one place.

/// Encoded key for one of the three fixed user-facing pixel labels.
///
/// Exactly three labels exist in Version 1 (Requirement 5.2). The display strings
/// are not stored here: copy lives in the Approved Verdict Copy catalog and its
/// String Catalog, addressed by key.
public enum PixelLabelKey: String, Codable, Sendable, Hashable, CaseIterable {
    /// The Positive Pixel Label.
    case signalsConsistentWithAIGeneration = "signals-consistent-with-ai-generation"

    /// The Non Positive Pixel Label.
    case noStrongSignalDetected = "no-strong-signal-detected"

    /// The Insufficient Evidence Outcome.
    case notEnoughSignal = "not-enough-signal"

    /// The metric category this label contributes to, fixed by Requirement 5.3.
    ///
    /// A Calibration Policy declares its own mapping and is rejected unless the
    /// declared mapping matches this one, so the requirement stays visible in the
    /// artifact instead of being implied by code.
    public var requiredMetricCategory: PixelMetricCategory {
        switch self {
        case .signalsConsistentWithAIGeneration: .positive
        case .noStrongSignalDetected: .nonPositive
        case .notEnoughSignal: .insufficient
        }
    }
}

/// The metric category a pixel label contributes to in release measurement.
///
/// Insufficient outcomes stay in the false-positive and true-positive denominators
/// (Requirements 5.16 and 5.17), which is why abstention is a category rather than
/// an exclusion.
public enum PixelMetricCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case positive
    case nonPositive = "non-positive"
    case insufficient
}

/// Encoded key for one of the five mutually exclusive enabled provenance states.
///
/// The unavailable source-lane state used when the capability is disabled is
/// deliberately absent: it is not a validator result, it bypasses fusion, and it
/// cannot appear in a fusion table or a Provenance Policy mapping (Requirements 6.9
/// and 7.10).
public enum ProvenanceStateKey: String, Codable, Sendable, Hashable, CaseIterable {
    case validated
    case invalid
    case absent
    case unsupported
    case indeterminate
}

/// Encoded key for the preservation status of the analyzed encoded bytes.
///
/// A fixture declares the status a route is expected to produce; the ingest path
/// records the status it actually observed. Neither may be upgraded toward
/// `originalBytes` without evidence (Requirements 2.9 through 2.11).
public enum BytePreservationStatusKey: String, Codable, Sendable, Hashable, CaseIterable {
    case originalBytes = "original-bytes"
    case platformTransformedCopy = "platform-transformed-copy"
    case unknown
}

/// Encoded key for one of the ten Analysis Error categories.
///
/// Used where an artifact has to name an expected terminal error, for example a
/// malformed-input fixture expecting `decoding-error`. The raw values are the exact
/// category names in the requirements' closed set.
public enum AnalysisErrorKey: String, Codable, Sendable, Hashable, CaseIterable {
    case unsupportedMedia = "unsupported-media"
    case unsupportedStaticFormat = "unsupported-static-format"
    case decodingError = "decoding-error"
    case resourceLimit = "resource-limit"
    case preprocessingError = "preprocessing-error"
    case modelLoadError = "model-load-error"
    case inferenceError = "inference-error"
    case invalidOutputError = "invalid-output-error"
    case calibrationInputError = "calibration-input-error"
    case handoffError = "handoff-error"
}

/// The two processes that run bounded DefAIke work with separate budgets.
///
/// Requirement 11.1 requires separate numeric budgets, Requirement 11.19 requires
/// separately reported measurements, and Requirement 11.20 requires independent
/// handoff approval, so the target is part of every budget, measurement, and
/// result record rather than an assumed context.
public enum ExecutionTarget: String, Codable, Sendable, Hashable, CaseIterable {
    case mainApplication = "main-application"
    case shareExtension = "share-extension"
}

/// Where a result was produced.
///
/// Physical-iPhone results are the only admissible release evidence for a device
/// gate. Simulator and development-Mac results are representable so a runner can
/// record and then reject them, rather than silently pooling them (Requirement
/// 13.16).
public enum ExecutionEnvironment: String, Codable, Sendable, Hashable, CaseIterable {
    case physicalIPhone = "physical-iphone"
    case iOSSimulator = "ios-simulator"
    case developmentMac = "development-mac"

    /// Whether a result from this environment can satisfy a physical-device gate.
    public var isPhysicalDeviceEvidence: Bool { self == .physicalIPhone }
}
