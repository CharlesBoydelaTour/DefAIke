import Foundation

// The closed set of physical-device gates and how one gate result is referenced.
//
// Requirement 13.17 requires every mandatory gate result to record its full version
// tuple, measured values, categorical comparisons, and pass or fail result.
// Requirement 13.16 makes physical-iPhone results the only admissible release evidence,
// with M3 Pro timing classified as development evidence.
//
// The schema enforces the second rule directly: a gate reference cannot claim a pass
// from a simulator or a development Mac. That value is representable so a runner can
// record what it observed, and rejected at exactly the point where it would otherwise
// become release evidence.

/// One mandatory physical-device gate.
public enum DeviceGate: String, Codable, Sendable, Hashable, CaseIterable {
    // Parity and correctness (Requirements 13.6 through 13.11).
    case preprocessingParity = "preprocessing-parity"
    case rawLogitParity = "raw-logit-parity"
    case rankAgreement = "rank-agreement"
    case categoricalAgreement = "categorical-agreement"
    case screenshotFidelity = "screenshot-fidelity"
    case routeByteParity = "route-byte-parity"
    case provenanceFixtures = "provenance-fixtures"

    // Main-application resources (Requirements 13.12 and 13.14).
    case coldModelLoad = "cold-model-load"
    case warmAnalysisLatency = "warm-analysis-latency"
    case mainApplicationPeakMemory = "main-application-peak-memory"
    case mainApplicationTemporaryStorage = "main-application-temporary-storage"
    case mainApplicationEnergy = "main-application-energy"
    case sustainedAnalysisThermal = "sustained-analysis-thermal"

    // Share Extension resources (Requirements 13.13 and 13.15).
    case handoffLatency = "handoff-latency"
    case shareExtensionPeakMemory = "share-extension-peak-memory"
    case shareExtensionTemporaryStorage = "share-extension-temporary-storage"
    case shareExtensionEnergy = "share-extension-energy"
    case sustainedHandoffThermal = "sustained-handoff-thermal"

    // Cancellation, interruption, accessibility, localization (Requirements 11.19,
    // 12.13, 12.17, and 15.6).
    case cancellationResidualWork = "cancellation-residual-work"
    case interruptionCleanup = "interruption-cleanup"
    case accessibilityMatrix = "accessibility-matrix"
    case localizationReadinessMatrix = "localization-readiness-matrix"

    /// Whether this gate applies only when Provenance Capability is enabled.
    ///
    /// A conditional gate still carries an explicit applicability decision; it is never
    /// silently skipped (Requirement 13.5).
    public var isProvenanceConditional: Bool { self == .provenanceFixtures }

    /// The target whose separately reported measurement set this gate belongs to, or
    /// `nil` for gates that are not a per-target resource measurement.
    public var measurementTarget: ExecutionTarget? {
        switch self {
        case .coldModelLoad, .warmAnalysisLatency, .mainApplicationPeakMemory,
             .mainApplicationTemporaryStorage, .mainApplicationEnergy, .sustainedAnalysisThermal:
            .mainApplication
        case .handoffLatency, .shareExtensionPeakMemory, .shareExtensionTemporaryStorage,
             .shareExtensionEnergy, .sustainedHandoffThermal:
            .shareExtension
        default:
            nil
        }
    }

    /// Every gate an allowlist entry must record a result for.
    public static let mandatoryGates = Set(DeviceGate.allCases)
}

/// A reference to one recorded gate result, with its applicability and outcome.
///
/// An allowlist entry carries these rather than raw measurements, so the entry stays
/// bounded while every claim remains traceable to an immutable result record.
public struct GateResultReference: Hashable, Codable, Sendable {
    public let gate: DeviceGate
    public let applicability: GateApplicability
    public let outcome: GateOutcome

    /// The immutable device-validation result this reference points at.
    public let result: EvidenceSource

    /// Where the result was produced.
    public let environment: ExecutionEnvironment

    public init(
        gate: DeviceGate,
        applicability: GateApplicability,
        outcome: GateOutcome,
        result: EvidenceSource,
        environment: ExecutionEnvironment
    ) throws {
        if applicability.isApplicable, outcome.isPassing, !environment.isPhysicalDeviceEvidence {
            throw ArtifactSchemaError.forbiddenValue(
                field: "gateResult[\(gate.rawValue)].environment",
                value: environment.rawValue,
                reason: "only physical-iPhone results can satisfy a device gate"
            )
        }
        if !applicability.isApplicable, outcome != .notExecuted {
            throw ArtifactSchemaError.inconsistentReference(
                field: "gateResult[\(gate.rawValue)].outcome",
                expected: GateOutcome.notExecuted.rawValue,
                found: outcome.rawValue
            )
        }
        self.gate = gate
        self.applicability = applicability
        self.outcome = outcome
        self.result = result
        self.environment = environment
    }

    /// Whether this gate is satisfied: either it passed on a physical iPhone, or an
    /// approved decision declared it inapplicable.
    public var isSatisfied: Bool {
        switch applicability {
        case .applicable:
            outcome.isPassing && environment.isPhysicalDeviceEvidence
        case let .notApplicable(decision):
            decision.isApproved
        }
    }

    private enum CodingKeys: String, CodingKey {
        case gate, applicability, outcome, result, environment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                gate: container.decode(DeviceGate.self, forKey: .gate),
                applicability: container.decode(GateApplicability.self, forKey: .applicability),
                outcome: container.decode(GateOutcome.self, forKey: .outcome),
                result: container.decode(EvidenceSource.self, forKey: .result),
                environment: container.decode(ExecutionEnvironment.self, forKey: .environment)
            )
        } catch let error as ArtifactSchemaError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}
