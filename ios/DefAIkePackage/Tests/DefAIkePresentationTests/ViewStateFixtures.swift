@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Synthetic snapshots for the view-state projection tests.
//
// Nothing here is approved anything. Every identifier is clearly synthetic, every catalogue
// carries localization keys rather than wording, and no tolerance, baseline, or release
// decision is expressed. The fixtures build a coherent session and then vary one field at a
// time so the projection can be checked for refusing what it should refuse.
//
// Session identifiers are spelled out per attempt rather than reused, because several tests
// turn on two attempts being distinguishable.

enum ViewStateFixture {

    // MARK: - Identity

    static func sessionID(_ value: String = "session.synthetic") -> AnalysisSessionID {
        AnalysisSessionID(value)!
    }

    static func identity(
        _ value: String = "session.synthetic",
        generation: UInt64 = 1
    ) -> SessionAttemptIdentity {
        SessionAttemptIdentity(sessionID: sessionID(value), attemptGeneration: generation)
    }

    // MARK: - Copy bindings for a named session

    /// A pixel-only binding for one session identifier.
    static func pixelOnlyBinding(
        session: String = "session.synthetic"
    ) throws -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: CopyFixture.catalog(),
            session: CopyFixture.sessionBinding(sessionID: session),
            capabilities: CopyFixture.capabilityManifest(),
            fusionRule: nil
        )
    }

    /// A provenance-plus-fusion binding for one session identifier.
    static func fusionBinding(
        session: String = "session.synthetic"
    ) throws -> ApprovedCopyBinding {
        try ApprovedCopyBinding.bind(
            catalog: CopyFixture.catalog(),
            session: CopyFixture.sessionBinding(
                sessionID: session,
                provenanceEnabled: true,
                fusionEnabled: true
            ),
            capabilities: CopyFixture.capabilityManifest(
                provenanceEnabled: true,
                fusionEnabled: true
            ),
            fusionRule: CopyFixture.fusionRule()
        )
    }

    // MARK: - Domain values

    static func quality(
        width: Int? = 1024,
        height: Int? = 768
    ) -> InputQualityRecord {
        InputQualityRecord(
            decodedWidthBeforeOrientation: width,
            decodedHeightBeforeOrientation: height
        )!
    }

    /// A pixel-only report: the provenance lane is unavailable, so no summary and no
    /// apparent-inconsistency notice are representable alongside it.
    static func pixelOnlyReport(
        session: String = "session.synthetic",
        pixel: PixelEvidence = .noStrongSignalDetected,
        bytePreservationStatus: BytePreservationStatus = .originalBytes
    ) -> EvidenceReport {
        EvidenceReport(
            binding: CopyFixture.sessionBinding(sessionID: session),
            pixel: pixel,
            provenance: .unavailable(.validatorNotCompiledIntoRelease),
            combinedSummary: nil,
            apparentInconsistency: nil,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: quality(),
            onDeviceProcessing: true,
            scope: .version1(id: CopyFixture.artifact("scope.evidence.synthetic"))
        )!
    }

    /// A report with an available provenance lane, a Combined Summary, and an
    /// apparent-inconsistency notice, so the completed projection resolves all four surfaces.
    static func fusedReport(
        session: String = "session.synthetic",
        pixel: PixelEvidence = .signalsConsistentWithAIGeneration
    ) -> EvidenceReport {
        EvidenceReport(
            binding: CopyFixture.sessionBinding(
                sessionID: session,
                provenanceEnabled: true,
                fusionEnabled: true
            ),
            pixel: pixel,
            provenance: .available(.absent),
            combinedSummary: CombinedSummary(
                copyKey: CopyFixture.summaryKeys[pixel.labelKey]!,
                fusionRuleID: CopyFixture.fusionRuleID
            ),
            apparentInconsistency: CopyFixture.localizationKey(for: .apparentInconsistency),
            bytePreservationStatus: .unknown,
            inputQuality: quality(),
            onDeviceProcessing: true,
            scope: .version1(id: CopyFixture.artifact("scope.evidence.synthetic"))
        )!
    }

    static func failure(
        session: String = "session.synthetic",
        error: AnalysisError = .decodingError,
        stage: AnalysisStage = .inputValidation,
        bytePreservationStatus: BytePreservationStatus? = .platformTransformedCopy,
        inputQuality: InputQualityRecord? = nil
    ) -> AnalysisFailureSnapshot {
        AnalysisFailureSnapshot(
            sessionID: sessionID(session),
            error: error,
            stage: stage,
            bytePreservationStatus: bytePreservationStatus,
            inputQuality: inputQuality ?? quality()
        )!
    }

    // MARK: - Snapshots

    static func working(
        session: String = "session.synthetic",
        generation: UInt64 = 1,
        progress: AnalysisProgressState = .indeterminate(stage: .inference),
        copy: ApprovedCopyBinding? = nil
    ) throws -> CoordinatorSnapshot {
        .session(
            AnalysisSessionSnapshot(
                identity: identity(session, generation: generation),
                phase: .working(progress),
                copy: try copy ?? pixelOnlyBinding(session: session)
            )
        )
    }

    static func ended(
        session: String = "session.synthetic",
        generation: UInt64 = 1,
        outcome: SessionTerminalOutcome,
        copy: ApprovedCopyBinding? = nil
    ) throws -> CoordinatorSnapshot {
        .session(
            AnalysisSessionSnapshot(
                identity: identity(session, generation: generation),
                phase: .ended(outcome),
                copy: try copy ?? pixelOnlyBinding(session: session)
            )
        )
    }

    /// One snapshot per screen family, so a test can assert something for all six.
    static func snapshotPerFamily() throws -> [AnalysisScreenFamily: CoordinatorSnapshot] {
        [
            .ready: .idle,
            .importing: .importing(ImportAttemptSnapshot(route: .photosPicker)),
            .active: try working(),
            .completed: try ended(outcome: .completed(pixelOnlyReport())),
            .cancelled: try ended(outcome: .cancelled),
            .error: try ended(outcome: .failed(failure())),
        ]
    }
}
