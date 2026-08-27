import DefAIkeDomain

// The transparency fields every completed report exposes.
//
// Requirement 8.12 requires the Result Presenter to expose the Model Bundle, model, and
// Calibration Policy versions bound to the session, the Byte Preservation Status, every
// pre-orientation input dimension recorded for the session, and the on-device-processing
// status. Requirement 10.18 adds the bound Model Bundle version, model identity, and
// integrity status. Requirement 4.12 requires the report to identify the Model Bundle,
// Core ML model, Preprocessing Contract, and Calibration Policy versions.
//
// The byte status lives with the limitations, because it comes with one. Everything else
// is here, and everything here is required, so nothing here is optional at the level the
// requirement speaks about:
//
//   * The bound component identifiers are six named non-optional members plus a
//     compiler-checked total switch over a closed component vocabulary. Adding a
//     component to the vocabulary fails to compile until a member supplies it, and
//     there is no dictionary a lookup could miss.
//   * The recorded dimensions are keyed by a closed vocabulary and projected over
//     `allCases`, so a view iterates the whole set. A dimension is absent from the
//     projection only when the session never recorded it, which the domain's own record
//     already distinguishes from zero.
//   * The on-device status is an enum over the recorded fact, not a `Bool` a view might
//     render only in one direction.
//   * The integrity status is the domain's ``ModelBundleIntegrityStatus``, which has
//     exactly one case, so "verified" is the only status a session can be bound to and
//     the only status this can show.
//
// What is deliberately not here:
//
//   * **Any digest.** The domain's integrity projection carries the verified manifest and
//     artifact digests; this exposes the status, the receipt version, the verification
//     policy version, and how many artifacts were covered. Digest internals are not a
//     user-facing transparency field.
//   * **A raw model output.** Requirement 8.15 permits one only when the approved
//     optional-detail artifact enables it and labels it uncalibrated. Neither exists, so
//     there is no member for the value at all. See
//     ``ExcludedResultControl/uncalibratedRawOutputDisclosure``.
//   * **Any benchmark performance claim.** Requirement 8.16 requires nine specific
//     accompanying facts, including sample counts and an uncertainty interval, for any
//     such claim. None is representable here - an interval is a numeric magnitude this
//     module has no field for - so a report presents no benchmark claim.
//   * **A field label or definition.** Requirement 8.14 requires optional technical
//     details to identify version and evidence metadata with definitions that preserve
//     the approved evidence limitations, and the closed approved-copy vocabulary has no
//     surface for one. Those gaps are enumerated in ``UnapprovedReportSurface`` and
//     nothing here invents a label to fill them.

/// One pre-orientation input dimension a session may have recorded.
///
/// Closed and enumerable, so a view iterates the vocabulary rather than reading three
/// separate members and possibly forgetting one (Requirement 8.12).
public enum PreOrientationDimension: String, Hashable, Sendable, CaseIterable {
    /// Actual decoded width before orientation metadata is applied.
    case decodedWidth = "decoded-width"
    /// Actual decoded height before orientation metadata is applied.
    case decodedHeight = "decoded-height"
    /// The lesser of the two recorded decoded dimensions.
    case shortEdge = "short-edge"
}

/// One recorded dimension and its measured value.
///
/// An `Int` because it is a count of pixels: an exact measurement, not a result
/// magnitude. Nothing here is a probability, a percentage, or a score, and the type
/// cannot hold a fractional value.
public struct RecordedDimension: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let dimension: PreOrientationDimension
    public let pixels: Int

    init(dimension: PreOrientationDimension, pixels: Int) {
        self.dimension = dimension
        self.pixels = pixels
    }
}

/// Every pre-orientation dimension the session recorded (Requirement 8.12).
///
/// Holds the domain's own record rather than copies of its fields, so a dimension
/// cannot be lost in translation, and projects the closed vocabulary so a view cannot
/// enumerate a partial set.
public struct RecordedDimensions: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The measured record this session produced.
    public let record: InputQualityRecord

    /// The measured value for one dimension, or `nil` when the session recorded none.
    ///
    /// `nil` means "not measured", which the domain keeps distinct from a measured
    /// value: a record either has both decoded dimensions or neither, and a short edge
    /// exists exactly when both do.
    public func pixels(for dimension: PreOrientationDimension) -> Int? {
        switch dimension {
        case .decodedWidth: record.decodedWidthBeforeOrientation
        case .decodedHeight: record.decodedHeightBeforeOrientation
        case .shortEdge: record.shortEdgeBeforeOrientation
        }
    }

    /// Every recorded dimension, in the vocabulary's declaration order.
    ///
    /// Built by mapping ``PreOrientationDimension/allCases``, so the set a view sees is
    /// the whole vocabulary filtered only by what was actually measured.
    public var recorded: [RecordedDimension] {
        PreOrientationDimension.allCases.compactMap { dimension in
            pixels(for: dimension).map {
                RecordedDimension(dimension: dimension, pixels: $0)
            }
        }
    }

    /// Dimensions the session did not record, in declaration order.
    ///
    /// Exposed so an absence is reportable as an absence. A view has no reason to
    /// substitute a value for one, and nothing here supplies a default that it could.
    public var unrecorded: [PreOrientationDimension] {
        PreOrientationDimension.allCases.filter { pixels(for: $0) == nil }
    }

    init(record: InputQualityRecord) {
        self.record = record
    }
}

/// Whether all analysis for this session ran on the user's device
/// (Requirement 8.12).
///
/// An enum over the recorded fact rather than a `Bool`, so both values are named and a
/// view that renders only one of them is visibly incomplete rather than silently
/// truthful-by-omission.
public enum OnDeviceProcessingStatus: String, Hashable, Sendable, CaseIterable {
    /// Every stage of this session's analysis ran on the user's device.
    case allProcessingOnDevice = "all-processing-on-device"

    /// The session did not record that all processing was on-device.
    ///
    /// Representable so the recorded fact can be shown as recorded. It is not a state
    /// this application produces: pixel inference and, where enabled, Content Credential
    /// validation both run locally, and the Privacy Controller permits no off-device
    /// transmission.
    case notRecordedAsFullyOnDevice = "not-recorded-as-fully-on-device"

    init(onDeviceProcessing: Bool) {
        self = onDeviceProcessing ? .allProcessingOnDevice : .notRecordedAsFullyOnDevice
    }
}

/// One component version a report discloses.
///
/// Closed vocabulary, so ``BoundComponentVersions`` can be projected totally and a
/// missing disclosure is a compile error rather than an absent row.
public enum DisclosedComponent: String, Hashable, Sendable, CaseIterable {
    /// The Model Bundle version the session was bound to (Requirements 8.12 and 10.18).
    case modelBundle = "model-bundle"
    /// The model checkpoint identity (Requirements 4.12 and 10.18).
    case modelCheckpoint = "model-checkpoint"
    /// The Core ML model component version (Requirement 4.12).
    case coreMLModel = "core-ml-model"
    /// The Preprocessing Contract version (Requirement 4.12).
    case preprocessingContract = "preprocessing-contract"
    /// The Calibration Policy version (Requirements 4.12 and 8.12).
    case calibrationPolicy = "calibration-policy"
    /// The Approved Verdict Copy compatibility identifier the session's copy was bound
    /// to (Requirement 8.1).
    case verdictCopyCompatibility = "verdict-copy-compatibility"
}

/// One component and the identifier the session recorded for it.
///
/// The identifier is an artifact version reference, which Requirement 8.12 requires the
/// report to expose. It is data rather than copy: it is never localized, never a claim,
/// and never rendered as a sentence. The *definition* that has to accompany it under
/// Requirement 8.14 is approved copy, and no approved surface for one exists yet -
/// see ``UnapprovedReportSurface/boundComponentVersionDefinition``.
public struct ComponentVersionReference: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let component: DisclosedComponent

    /// The recorded artifact identifier, exactly as the session binding holds it.
    public let identifier: String

    init(component: DisclosedComponent, identifier: String) {
        self.component = component
        self.identifier = identifier
    }
}

/// Every component version bound to the Analysis Session (Requirements 4.12, 8.12,
/// and 10.18).
///
/// Six non-optional members taken from the immutable session binding. Because the
/// binding is a snapshot taken when the input was accepted, a later activation or
/// rollback cannot change what this discloses.
public struct BoundComponentVersions: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let modelBundle: ModelBundleID
    public let modelCheckpoint: ModelCheckpointIdentifier
    public let coreMLModel: ArtifactID
    public let preprocessingContract: ArtifactID
    public let calibrationPolicy: ArtifactID
    public let verdictCopyCompatibility: ArtifactID

    /// The recorded identifier for one component.
    ///
    /// A total switch over a closed vocabulary with no `default`, so adding a component
    /// does not compile until a stored property supplies it. That is what makes "every
    /// required version is disclosed" a compile-time fact rather than a test's opinion.
    public func identifier(for component: DisclosedComponent) -> String {
        switch component {
        case .modelBundle: modelBundle.rawValue
        case .modelCheckpoint: modelCheckpoint.rawValue
        case .coreMLModel: coreMLModel.rawValue
        case .preprocessingContract: preprocessingContract.rawValue
        case .calibrationPolicy: calibrationPolicy.rawValue
        case .verdictCopyCompatibility: verdictCopyCompatibility.rawValue
        }
    }

    /// Every disclosure, in the vocabulary's declaration order.
    public var disclosures: [ComponentVersionReference] {
        DisclosedComponent.allCases.map {
            ComponentVersionReference(component: $0, identifier: identifier(for: $0))
        }
    }

    init(binding: AnalysisSessionBinding) {
        self.modelBundle = binding.modelBundleID
        self.modelCheckpoint = binding.modelIdentity.checkpointIdentifier
        self.coreMLModel = binding.coreMLModelVersion
        self.preprocessingContract = binding.preprocessingContractID
        self.calibrationPolicy = binding.calibrationPolicyID
        self.verdictCopyCompatibility = binding.verdictCopyCompatibilityID
    }
}

/// The verified Model Bundle integrity status (Requirement 10.18).
///
/// ``ModelBundleIntegrityStatus`` has exactly one case, so an unverified or partially
/// verified bundle is not representable in a session binding and therefore not here
/// either. What is shown is the status, which receipt and Bundle Verification Policy
/// version produced it, and how many artifacts the verification covered.
///
/// No digest is exposed. The verification record holds them; a transparency field
/// reports that verification succeeded and under which policy version.
public struct BundleIntegrityDisclosure: Hashable, Sendable, ProbabilityFreePresentationModel {
    public let status: ModelBundleIntegrityStatus
    public let activationReceipt: ArtifactID
    public let verificationPolicy: ArtifactID

    /// How many bundle artifacts the verification covered.
    ///
    /// A count, and the domain refuses an empty inventory, so this is always at least
    /// one.
    public let verifiedArtifactCount: Int

    init(integrity: VerifiedBundleIntegrity) {
        self.status = integrity.status
        self.activationReceipt = integrity.activationReceiptID
        self.verificationPolicy = integrity.verificationPolicyID
        self.verifiedArtifactCount = integrity.verifiedArtifactDigests.count
    }
}

/// The transparency fields a completed report exposes (Requirements 4.12, 8.12,
/// and 10.18).
///
/// Every member is non-optional. Whether a view puts them behind a disclosure control
/// is a layout decision; whether they exist is not.
public struct EvidenceTechnicalDetails: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Every component version bound to the session.
    public let components: BoundComponentVersions

    /// Every pre-orientation dimension the session recorded.
    public let dimensions: RecordedDimensions

    /// Whether all analysis ran on the user's device.
    public let onDeviceProcessing: OnDeviceProcessingStatus

    /// The verified Model Bundle integrity status.
    public let integrity: BundleIntegrityDisclosure

    init(
        components: BoundComponentVersions,
        dimensions: RecordedDimensions,
        onDeviceProcessing: OnDeviceProcessingStatus,
        integrity: BundleIntegrityDisclosure
    ) {
        self.components = components
        self.dimensions = dimensions
        self.onDeviceProcessing = onDeviceProcessing
        self.integrity = integrity
    }

    /// Projects the transparency fields of one report.
    ///
    /// Cannot fail: every value is read from the report and its immutable binding, and
    /// none of them needs approved copy to exist. The approved *definitions* that
    /// Requirement 8.14 requires alongside them do not exist yet, and this deliberately
    /// does not substitute for them.
    init(report: EvidenceReport) {
        self.init(
            components: BoundComponentVersions(binding: report.binding),
            dimensions: RecordedDimensions(record: report.inputQuality),
            onDeviceProcessing: OnDeviceProcessingStatus(
                onDeviceProcessing: report.onDeviceProcessing
            ),
            integrity: BundleIntegrityDisclosure(
                integrity: report.binding.modelBundleIntegrity
            )
        )
    }
}
