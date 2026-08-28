import Testing

@testable import DefAIkeDomain

// The ten Analysis Error categories and the three disjoint terminal outcomes.
//
// `CoreValueInvariantTests` checks the raw-value list and one outcome triple. This is
// the full matrix: every error, every pixel label crossed with every representable
// provenance lane, and the structural reasons a terminal outcome cannot be two things
// at once or carry evidence it should not have.
//
// The point of the matrix is that disjointness here is a property of the *types*, not
// of the coordinator that will drive them. A late framework result arriving after a
// terminal commit has nowhere to land, because `cancelled` has no payload and `failed`
// has no evidence field. That is what makes "cancellation prevents every evidence
// commit" checkable now, before any adapter exists (Requirements 11.17, 11.18, 15.7).

@Suite("Analysis Error vocabulary")
struct AnalysisErrorVocabularyTests {

    /// The exact ten category names the requirements fix, in requirement order.
    static let requiredRawValues = [
        "unsupported-media",
        "unsupported-static-format",
        "decoding-error",
        "resource-limit",
        "preprocessing-error",
        "model-load-error",
        "inference-error",
        "invalid-output-error",
        "calibration-input-error",
        "handoff-error",
    ]

    @Test("Exactly ten categories exist, with their exact raw values in order")
    func exactTenCategories() {
        #expect(AnalysisError.allCases.count == 10)
        #expect(AnalysisError.allCases.map(\.rawValue) == Self.requiredRawValues)
    }

    @Test("Each required raw value resolves to exactly one category")
    func rawValuesResolve() throws {
        for raw in Self.requiredRawValues {
            let error = try #require(
                AnalysisError(rawValue: raw),
                "'\(raw)' is not an Analysis Error category"
            )
            #expect(error.rawValue == raw)
        }
        #expect(Set(AnalysisError.allCases.map(\.rawValue)).count == 10)
    }

    @Test("A category outside the closed set does not exist")
    func unknownCategoryRejected() {
        // Two failure kinds are deliberately outside the vocabulary: a provider
        // retrieval that fails before any bytes exist, and a failed startup gate.
        // Neither may be spelled as an Analysis Error.
        for absent in [
            "provider-error",
            "startup-gate-error",
            "cleanup-error",
            "timeout",
            "unknown-error",
            "decoding_error",
            "Decoding-Error",
        ] {
            #expect(AnalysisError(rawValue: absent) == nil, "'\(absent)' became a category")
        }
    }

    @Test("The artifact key vocabulary names the same ten categories")
    func artifactKeysMatch() {
        // An artifact names an expected terminal error with `AnalysisErrorKey`, and the
        // session commits an `AnalysisError`. If the two lists ever drifted, a fixture
        // could expect an error the session cannot produce.
        #expect(AnalysisErrorKey.allCases.count == 10)
        #expect(AnalysisErrorKey.allCases.map(\.rawValue) == Self.requiredRawValues)
        #expect(
            AnalysisError.allCases.map { String(describing: $0) }
                == AnalysisErrorKey.allCases.map { String(describing: $0) }
        )
    }

    @Test("Every stage that can commit an error is in the closed stage vocabulary")
    func stagesAreClosed() {
        // A failure records where it was detected. The stage set is closed so a
        // failure location cannot be an invented or free-form name.
        #expect(AnalysisStage.allCases.count == 10)
        #expect(Set(AnalysisStage.allCases.map(\.rawValue)).count == 10)
        for stage in AnalysisStage.allCases {
            #expect(SessionValue.snapshot(stage: stage) != nil)
        }
    }
}

@Suite("Disjoint terminal outcomes")
struct TerminalOutcomeTests {

    /// How many of the three terminal predicates `outcome` answers yes to.
    static func claimedKinds(_ outcome: SessionTerminalOutcome) -> Int {
        [outcome.isCompleted, outcome.isCancelled, outcome.isFailed].filter { $0 }.count
    }

    @Test("The label and lane space is fully representable")
    func laneSpaceIsRepresentable() {
        // Three labels crossed with three unavailable reasons and five enabled states.
        // Every combination is a legitimate completed session, including an
        // insufficient pixel result beside a validated claim.
        let laneCount = UnavailableReason.allCases.count + ProvenanceCategory.allCases.count
        #expect(laneCount == 8)
        #expect(SessionValue.allLanes.count == laneCount)
        #expect(SessionValue.allReports.count == PixelEvidence.allCases.count * laneCount)
    }

    @Test("A completed outcome is completed and nothing else",
          arguments: SessionValue.allReports)
    func completedIsDisjoint(report: EvidenceReport) {
        let outcome = SessionTerminalOutcome.completed(report)

        #expect(Self.claimedKinds(outcome) == 1)
        #expect(outcome.evidenceReport == report)
        #expect(outcome.error == nil)
        #expect(outcome.failure == nil)
        #expect(outcome.endReason == .completed)
    }

    @Test("A failed outcome carries exactly one error and no evidence",
          arguments: AnalysisError.allCases)
    func failedIsDisjoint(error: AnalysisError) throws {
        let snapshot = try #require(SessionValue.snapshot(error: error))
        let outcome = SessionTerminalOutcome.failed(snapshot)

        #expect(Self.claimedKinds(outcome) == 1)
        #expect(outcome.error == error)
        #expect(outcome.failure == snapshot)
        #expect(outcome.evidenceReport == nil)
        #expect(outcome.endReason == .error)

        // Requirement 11.18: one category, and no evidence anywhere in the value.
        let evidence = EvidenceReachabilityAudit.evidencePaths(in: outcome)
        #expect(evidence.isEmpty, "\(evidence)")
    }

    @Test("A cancelled outcome carries no payload at all")
    func cancelledIsEmpty() {
        let outcome = SessionTerminalOutcome.cancelled

        #expect(Self.claimedKinds(outcome) == 1)
        #expect(outcome.evidenceReport == nil)
        #expect(outcome.error == nil)
        #expect(outcome.failure == nil)
        #expect(outcome.endReason == .cancelled)
        #expect(EvidenceReachabilityAudit.evidencePaths(in: outcome).isEmpty)
        // Nothing is reachable from a cancelled outcome, so a late result has nowhere
        // to land even in principle.
        #expect(Mirror(reflecting: outcome).children.isEmpty)
    }

    @Test("Evidence is reachable from a completed outcome, so the audit is not blanket")
    func completedCarriesEvidence() throws {
        let report = try #require(SessionValue.report(pixel: .notEnoughSignal))
        let paths = EvidenceReachabilityAudit.evidencePaths(
            in: SessionTerminalOutcome.completed(report)
        )
        #expect(paths.contains { $0.hasSuffix(".pixel") })
        #expect(paths.contains { $0.hasSuffix(".provenance") })
        #expect(paths.contains { $0.hasSuffix(".scope") })
    }

    @Test("Only a terminal outcome's own three reasons are selectable")
    func endReasonsCoverTheThreeOutcomes() throws {
        let report = try #require(SessionValue.report())
        let snapshot = try #require(SessionValue.snapshot())
        let reasons = [
            SessionTerminalOutcome.completed(report).endReason,
            SessionTerminalOutcome.cancelled.endReason,
            SessionTerminalOutcome.failed(snapshot).endReason,
        ]
        #expect(Set(reasons).count == 3)
        // `interrupted` and `abandoned` describe material found on a later start, not
        // a session that reached a terminal outcome in this process, so no terminal
        // outcome selects either.
        #expect(
            Set(SessionEndReason.allCases).subtracting(reasons)
                == [.interrupted, .abandoned]
        )
    }

    @Test("A failure preserves what was measured before it, and only that")
    func failurePreservesMeasurements() throws {
        let measured = try #require(SessionValue.snapshot())
        #expect(measured.inputQuality?.shortEdgeBeforeOrientation == 600)
        #expect(measured.bytePreservationStatus == .unknown)

        // A session can fail before anything was measured. Neither field is ever
        // reconstructed, defaulted, or guessed, so both stay absent.
        let unmeasured = try #require(
            AnalysisFailureSnapshot(
                sessionID: SessionValue.session(),
                error: .handoffError,
                stage: .handoffVerification,
                bytePreservationStatus: nil,
                inputQuality: nil
            )
        )
        #expect(unmeasured.bytePreservationStatus == nil)
        #expect(unmeasured.inputQuality == nil)
        #expect(unmeasured.error == .handoffError)
    }

    @Test("A new session never inherits a failed session's identity or category")
    func failureDoesNotLeakIntoTheNextSession() throws {
        let failed = try #require(SessionValue.snapshot(error: .resourceLimit))
        let next = try #require(
            AnalysisFailureSnapshot(
                sessionID: SessionValue.session("session.next"),
                error: .decodingError,
                stage: .inputValidation,
                bytePreservationStatus: nil,
                inputQuality: nil
            )
        )
        #expect(failed.sessionID != next.sessionID)
        #expect(failed.error != next.error)
    }
}

@Suite("Unrepresentable terminal combinations")
struct UnrepresentableOutcomeTests {

    @Test("An unavailable lane cannot carry a Combined Summary",
          arguments: UnavailableReason.allCases)
    func unavailableLaneForbidsSummary(reason: UnavailableReason) {
        // Requirement 7.10: with no provenance evidence there is nothing to fuse, so
        // the combination is not representable rather than merely discouraged.
        #expect(SessionValue.report(provenance: .unavailable(reason)) != nil)
        #expect(
            SessionValue.report(
                provenance: .unavailable(reason),
                combinedSummary: SessionValue.summary()
            ) == nil
        )
    }

    @Test("An unavailable lane cannot carry an apparent inconsistency",
          arguments: UnavailableReason.allCases)
    func unavailableLaneForbidsInconsistency(reason: UnavailableReason) {
        // Requirement 7.8 identifies an inconsistency *between* two lanes. With one
        // lane absent there is nothing for the pixel lane to disagree with.
        #expect(
            SessionValue.report(
                provenance: .unavailable(reason),
                apparentInconsistency: SessionValue.copyKey("copy.inconsistency")
            ) == nil
        )
    }

    @Test("An available lane may carry a summary and an inconsistency")
    func availableLaneAllowsBoth() {
        // The negative control: the rejections above are about the unavailable lane,
        // not about the fields themselves.
        for evidence in SessionValue.enabledEvidence {
            #expect(
                SessionValue.report(
                    provenance: .available(evidence),
                    combinedSummary: SessionValue.summary(),
                    apparentInconsistency: SessionValue.copyKey("copy.inconsistency")
                ) != nil
            )
        }
    }

    @Test("An unavailable lane exposes no evidence and no fusion key",
          arguments: UnavailableReason.allCases)
    func unavailableLaneBypassesFusion(reason: UnavailableReason) {
        let lane = ProvenanceLane.unavailable(reason)
        #expect(lane.evidence == nil)
        #expect(lane.category == nil)
        #expect(!lane.isAvailable)
        #expect(lane.unavailableReason == reason)
    }

    @Test("Each enabled state exposes exactly its own fusion key")
    func enabledLaneCategories() {
        for evidence in SessionValue.enabledEvidence {
            let lane = ProvenanceLane.available(evidence)
            #expect(lane.isAvailable)
            #expect(lane.category == evidence.category)
            #expect(lane.unavailableReason == nil)
        }
        #expect(
            SessionValue.enabledEvidence.map(\.category) == ProvenanceCategory.allCases
        )
    }

    @Test("A Share ticket cannot claim the picker route or an empty payload")
    func ticketRouteAndPayloadGoverned() {
        #expect(SessionValue.ticket() != nil)
        #expect(SessionValue.ticket(route: .photosPicker) == nil)
        #expect(SessionValue.ticket(byteCount: 0) == nil)
    }

    @Test("A Share ticket cannot claim a status its basis does not support")
    func ticketStatusMatchesBasis() {
        // A tampered ticket that flips only the status, or only the basis, is
        // unconstructible, so the mismatch is caught at decode rather than by a
        // comparison the claim path might forget.
        for basis in PreservationBasis.allCases {
            for status in BytePreservationStatus.allCases {
                let ticket = SessionValue.ticket(
                    preservationStatus: status,
                    preservationBasis: basis
                )
                #expect(
                    (ticket != nil) == basis.supports(status),
                    "basis \(basis.rawValue) with status \(status.rawValue)"
                )
            }
        }
    }
}
