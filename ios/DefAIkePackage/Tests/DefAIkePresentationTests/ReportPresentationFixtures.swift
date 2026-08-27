@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Synthetic completed screens for the result-presentation tests.
//
// Nothing here is approved anything. Every identifier is clearly synthetic, every
// catalogue carries localization keys rather than wording, and no tolerance, baseline,
// capability decision, or release conclusion is expressed.
//
// Screens are built by running the real projection over a real snapshot rather than by
// calling ``CompletedScreen``'s initializer directly. That matters: it means the lanes a
// card is assembled from are the lanes the projection resolves, so these tests cannot pass
// against a screen the application could not produce.

/// Why a fixture could not produce the screen it was asked for.
enum ReportFixtureFailure: Error {
    /// The projection produced a family other than completed.
    case notCompletedScreen(AnalysisScreenFamily)
}

enum ReportFixture {

    static let provenancePolicyID = CopyFixture.artifact("policy.provenance.synthetic")

    // MARK: - Copy bindings

    /// A provenance-enabled binding with no fusion rule, for one session identifier.
    static func provenanceBinding(
        session: String = "session.synthetic"
    ) throws -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: CopyFixture.catalog(),
            session: CopyFixture.sessionBinding(sessionID: session, provenanceEnabled: true),
            capabilities: CopyFixture.capabilityManifest(provenanceEnabled: true),
            fusionRule: nil
        )
    }

    // MARK: - Provenance lanes

    /// One lane per enabled provenance state, keyed by category.
    ///
    /// Payload contents are synthetic and only their shape matters. The explanation keys a
    /// Provenance Policy would select are present because the domain types require them;
    /// the presentation does not render them, because the closed approved-copy vocabulary
    /// has one key per state rather than one per policy explanation.
    static func availableLane(_ category: ProvenanceCategory) -> ProvenanceLane {
        switch category {
        case .validated:
            .available(
                .validated(
                    ValidatedClaimSummary(
                        provenancePolicyID: provenancePolicyID,
                        bindingStatus: .boundToInspectedBytes,
                        signerFields: [],
                        assertionFields: []
                    )
                )
            )
        case .invalid:
            .available(
                .invalid(
                    InvaliditySummary(
                        provenancePolicyID: provenancePolicyID,
                        category: .byteBinding,
                        explanationKey: CopyFixture.copyKey("copy.provenance.invalid-binding")
                    )
                )
            )
        case .absent:
            .available(.absent)
        case .unsupported:
            .available(
                .unsupported(
                    UnsupportedFeatureSummary(
                        provenancePolicyID: provenancePolicyID,
                        explanationKey: CopyFixture.copyKey("copy.provenance.unsupported"),
                        unsupportedFeatures: [DisplaySafeText("synthetic feature")!]
                    )
                )
            )
        case .indeterminate:
            .available(
                .indeterminate(
                    IndeterminateSummary(
                        provenancePolicyID: provenancePolicyID,
                        explanationKey: CopyFixture.copyKey("copy.provenance.indeterminate")
                    )
                )
            )
        }
    }

    /// Every lane state a completed report can carry: two unavailable reasons and five
    /// enabled states.
    static var allLanes: [ProvenanceLane] {
        UnavailableReason.allCases.map(ProvenanceLane.unavailable)
            + ProvenanceCategory.allCases.map(availableLane)
    }

    // MARK: - Reports

    /// A provenance-enabled report with no Combined Summary.
    ///
    /// `apparentInconsistency` is representable here because the lane is available; the
    /// domain refuses a notice alongside an unavailable lane.
    static func provenanceReport(
        session: String = "session.synthetic",
        pixel: PixelEvidence = .signalsConsistentWithAIGeneration,
        lane: ProvenanceLane,
        inconsistent: Bool = false,
        bytePreservationStatus: BytePreservationStatus = .originalBytes,
        inputQuality: InputQualityRecord? = nil,
        onDeviceProcessing: Bool = true
    ) -> EvidenceReport {
        EvidenceReport(
            binding: CopyFixture.sessionBinding(
                sessionID: session,
                provenanceEnabled: lane.isAvailable
            ),
            pixel: pixel,
            provenance: lane,
            combinedSummary: nil,
            apparentInconsistency: inconsistent && lane.isAvailable
                ? CopyFixture.localizationKey(for: .apparentInconsistency)
                : nil,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality ?? ViewStateFixture.quality(),
            onDeviceProcessing: onDeviceProcessing,
            scope: .version1(id: CopyFixture.artifact("scope.evidence.synthetic"))
        )!
    }

    // MARK: - Completed screens

    /// Projects one completed screen through the real projection.
    static func completedScreen(
        report: EvidenceReport,
        copy: ApprovedCopyBinding,
        generation: UInt64 = 1
    ) throws -> CompletedScreen {
        let snapshot = CoordinatorSnapshot.session(
            AnalysisSessionSnapshot(
                identity: SessionAttemptIdentity(
                    sessionID: report.binding.sessionID,
                    attemptGeneration: generation
                ),
                phase: .ended(.completed(report)),
                copy: copy
            )
        )
        let screen = try AnalysisScreen.projecting(snapshot)
        guard case let .completed(completed) = screen else {
            throw ReportFixtureFailure.notCompletedScreen(screen.family)
        }
        return completed
    }

    /// A pixel-only completed screen: the provenance lane is unavailable.
    static func pixelOnlyScreen(
        pixel: PixelEvidence = .noStrongSignalDetected,
        bytePreservationStatus: BytePreservationStatus = .originalBytes
    ) throws -> CompletedScreen {
        try completedScreen(
            report: ViewStateFixture.pixelOnlyReport(
                pixel: pixel,
                bytePreservationStatus: bytePreservationStatus
            ),
            copy: try ViewStateFixture.pixelOnlyBinding()
        )
    }

    /// A provenance-enabled completed screen with no Combined Summary.
    static func provenanceScreen(
        pixel: PixelEvidence = .signalsConsistentWithAIGeneration,
        lane: ProvenanceLane,
        inconsistent: Bool = false,
        bytePreservationStatus: BytePreservationStatus = .originalBytes,
        inputQuality: InputQualityRecord? = nil,
        onDeviceProcessing: Bool = true
    ) throws -> CompletedScreen {
        let report = provenanceReport(
            pixel: pixel,
            lane: lane,
            inconsistent: inconsistent,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality,
            onDeviceProcessing: onDeviceProcessing
        )
        let copy =
            lane.isAvailable
            ? try provenanceBinding()
            : try ViewStateFixture.pixelOnlyBinding()
        return try completedScreen(report: report, copy: copy)
    }

    /// A completed screen with a Combined Summary and an apparent-inconsistency notice.
    static func fusedScreen(
        pixel: PixelEvidence = .signalsConsistentWithAIGeneration
    ) throws -> CompletedScreen {
        try completedScreen(
            report: ViewStateFixture.fusedReport(pixel: pixel),
            copy: try ViewStateFixture.fusionBinding()
        )
    }

    // MARK: - Assembled presentations

    /// The binding a screen was projected through, paired with the screen.
    ///
    /// Assembly takes both because the completed screen carries resolved lanes rather than
    /// the binding itself.
    static func presentation(
        screen: CompletedScreen,
        copy: ApprovedCopyBinding
    ) throws -> EvidenceReportPresentation {
        try EvidenceReportPresentation.assembling(screen, copy: copy)
    }

    /// A pixel-only presentation, the composition this release actually ships.
    static func pixelOnlyPresentation(
        pixel: PixelEvidence = .noStrongSignalDetected,
        bytePreservationStatus: BytePreservationStatus = .originalBytes
    ) throws -> EvidenceReportPresentation {
        try presentation(
            screen: try pixelOnlyScreen(
                pixel: pixel,
                bytePreservationStatus: bytePreservationStatus
            ),
            copy: try ViewStateFixture.pixelOnlyBinding()
        )
    }

    /// A provenance-enabled presentation for one lane state.
    static func provenancePresentation(
        pixel: PixelEvidence = .signalsConsistentWithAIGeneration,
        lane: ProvenanceLane,
        inconsistent: Bool = false,
        bytePreservationStatus: BytePreservationStatus = .originalBytes,
        inputQuality: InputQualityRecord? = nil,
        onDeviceProcessing: Bool = true
    ) throws -> EvidenceReportPresentation {
        let screen = try provenanceScreen(
            pixel: pixel,
            lane: lane,
            inconsistent: inconsistent,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality,
            onDeviceProcessing: onDeviceProcessing
        )
        let copy =
            lane.isAvailable
            ? try provenanceBinding()
            : try ViewStateFixture.pixelOnlyBinding()
        return try presentation(screen: screen, copy: copy)
    }

    /// A presentation that shows a Combined Summary.
    static func fusedPresentation(
        pixel: PixelEvidence = .signalsConsistentWithAIGeneration
    ) throws -> EvidenceReportPresentation {
        try presentation(
            screen: try fusedScreen(pixel: pixel),
            copy: try ViewStateFixture.fusionBinding()
        )
    }
}
