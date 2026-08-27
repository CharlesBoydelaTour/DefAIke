import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Requirements 6.4-6.21, 7.2-7.17, 8.1-8.18, 9.15, 9.16, 11.17, and 11.18 as value
// snapshots, one case per state, over closed vocabularies enumerated rather than sampled.
//
// Every presentation surface in this module is a deterministic value projected from an
// input: `AnalysisScreen.projecting(_:)`, `EvidenceReportPresentation.assembling(_:copy:)`,
// and `DisclosureScreens.projecting(_:)` are all pure functions of one argument, and all
// three are already asserted to satisfy `first == second`. So a snapshot here is a snapshot
// of the projected *values* - no view hierarchy, no rendering, no simulator, no device, and
// no image-snapshot dependency. What is pinned is a written-out expected value per state,
// so a change to any projection shows up as a diff rather than as a silently different
// screen.
//
// Tasks 11.1 through 11.4, 11.6, and 11.7 already assert that each projection is correct,
// refuses what it must refuse, and is probability-free. This file adds the dimension those
// left open: exhaustive per-state coverage with the expected value spelled out, plus an
// assertion on the *size* of every vocabulary it enumerates, so the suite fails when a
// vocabulary grows rather than quietly covering a smaller share of it.
//
// ## What is snapshotted
//
// | Dimension | Cases | Where |
// |---|---|---|
// | Pixel labels | 3 | ``PixelLaneSnapshotTests`` |
// | Provenance lane states | 7 (2 unavailable reasons + 5 enabled categories) | ``ProvenanceLaneSnapshotTests`` |
// | Byte preservation statuses | 3 | ``BytePreservationSnapshotTests`` |
// | Apparent inconsistency | 2 (declared, undeclared) | ``ApparentInconsistencySnapshotTests`` |
// | Combined Summary | 3 (shown + both omission reasons) | ``CombinedSummarySnapshotTests`` |
// | Analysis Errors and recovery | 10 x 2 preservation shapes | ``AnalysisErrorSnapshotTests`` |
// | Disclosure destinations | 4 screens, 2 capability compositions | ``DisclosureScreenSnapshotTests`` |
// | Exact copy | 3 fixed strings; every other surface blocked | ``ExactCopySnapshotTests`` |
// | Forbidden controls and prohibited claims | every enumerated snapshot above | ``ForbiddenControlSnapshotTests`` |
//
// ## Facts this file pins rather than papers over
//
// Each is the measured current state. Asserting it is what makes a change to it visible.
//
//   * **Requirement 6.16 is satisfied for a superset.** Nothing in the application records
//     whether an image is a screenshot, so the approved screenshot explanation is attached
//     to *every* enabled `absent` result rather than only to screenshots. The superset is
//     what is asserted, together with the recorded reason
//     (``UnavailableEvidenceInput/screenshotOriginDetermination``).
//   * **Requirement 1.15 is partly blocked.** The scope-and-limitations screen accounts for
//     all five properties structurally and can frame only three of them in approved words.
//   * **Requirement 14.14's correction channel has no address anywhere**, so
//     ``CorrectionChannelScreen/presentsAnActionableAddress`` is `false` by design.
//   * **The copy catalog is nearly empty.** `Localizable.xcstrings` carries only the three
//     fixed pixel-label keys. "Exact copy" therefore means those three strings are exact
//     and every other approved value is a recorded release-validation finding, never a
//     rendered sentence. Nothing here fabricates copy to make a snapshot render.
//   * **Retry is not operable on the error screen.** The error screen offers
//     ``SessionRecovery/selectAnotherImage`` and exposes it as
//     ``AccessibleElementIdentity/analysisErrorRecovery``, while the retry workflow requires
//     ``AccessibleElementIdentity/imageSelectionControl``. Task 11.9 pins that mismatch as
//     its own defect; nothing below claims retry is operable, and the recovery snapshots
//     here assert only what the error screen itself offers.
//
// Every identifier appearing in an expected value below is synthetic fixture data or a
// domain-owned stable key. No expected value is approved wording, and none is a product
// decision.

// MARK: - The stable-key renderer

/// Renders a projected presentation value as ordered `field = value` lines.
///
/// Deliberately built from stable keys only: enum raw values, surface descriptions, and
/// synthetic artifact identifiers. It never reads a user-facing sentence, because outside
/// the three fixed pixel labels there is no approved sentence to read - so a snapshot
/// cannot become a test of unapproved copy.
///
/// Lines rather than one blob, so a failure names the field that changed.
enum PresentationSnapshot {

    // MARK: Copy addresses

    /// One resolved reference, as the surface it is approved for.
    ///
    /// The surface's stable key rather than the localization key: the surface vocabulary is
    /// domain-owned and stable, while the localization key in these tests comes from the
    /// fixture's own derivation. Both are checked - the key is compared against the bound
    /// catalogue's approved key separately - but only one belongs in a snapshot.
    static func address(_ reference: ResolvedCopyReference) -> String {
        reference.surface.description
    }

    static func laneState(_ state: ProvenanceLanePresentationState) -> String {
        switch state {
        case let .unavailable(reason): "unavailable/\(reason.rawValue)"
        case let .available(category): "available/\(category.rawValue)"
        }
    }

    static func claimBinding(_ disclosure: ClaimBindingDisclosure) -> String {
        switch disclosure {
        case let .validatedClaimBinding(reference): "validated-claim-binding/\(address(reference))"
        case .notApplicable: "not-applicable"
        }
    }

    static func screenshot(_ disclosure: ScreenshotProvenanceDisclosure) -> String {
        switch disclosure {
        case let .shownForAbsentCredential(reference):
            "shown-for-absent-credential/\(address(reference))"
        case .notApplicable: "not-applicable"
        }
    }

    static func inconsistency(_ notice: ApparentInconsistencyNotice) -> String {
        switch notice {
        case .none: "none"
        case let .declared(reference): "declared/\(address(reference))"
        }
    }

    static func summary(_ section: CombinedSummarySection) -> String {
        switch section {
        case let .omitted(reason): "omitted/\(reason.rawValue)"
        case let .shown(shown):
            "shown/\(address(shown.summaryCopy))/rule=\(shown.fusionRuleID.rawValue)"
        }
    }

    // MARK: Aggregates

    /// The whole completed-report presentation, in a fixed field order.
    static func lines(of presentation: EvidenceReportPresentation) -> [String] {
        let cards = presentation.cards
        let limitations = presentation.limitations
        let technical = presentation.technicalDetails
        let paths = presentation.disclosurePaths

        let dimensions = technical.dimensions.recorded
            .map { "\($0.dimension.rawValue)=\($0.pixels)" }
            .joined(separator: ",")
        let unrecorded = technical.dimensions.unrecorded
            .map(\.rawValue)
            .joined(separator: ",")
        let components = technical.components.disclosures
            .map { "\($0.component.rawValue)=\($0.identifier)" }
            .joined(separator: ",")
        let covered = limitations.coveredScopes.map(\.rawValue).joined(separator: ",")
        let uncovered = limitations.uncoveredScopes.map(\.rawValue).joined(separator: ",")

        return [
            "identity.session = \(presentation.identity.sessionID.rawValue)",
            "identity.attempt = \(presentation.identity.attemptGeneration)",
            "pixel.evidence = \(cards.pixel.evidence.rawValue)",
            "pixel.fixedText = \(cards.pixel.fixedLabelText.value)",
            "pixel.labelCopy = \(address(cards.pixel.lane.labelCopy))",
            "pixel.explanationCopy = \(address(cards.pixel.lane.explanationCopy))",
            "provenance.state = \(laneState(cards.provenance.state))",
            "provenance.distinction = \(cards.provenance.distinction.rawValue)",
            "provenance.stateCopy = \(address(cards.provenance.lane.stateCopy))",
            "provenance.claimBinding = \(claimBinding(cards.provenance.claimBinding))",
            "provenance.screenshot = \(screenshot(cards.provenance.screenshotExplanation))",
            "apparentInconsistency = \(inconsistency(presentation.apparentInconsistency))",
            "combinedSummary = \(summary(presentation.combinedSummary))",
            "limitations.scopeCopy = \(address(limitations.scopeCopy))",
            "limitations.falseResultCopy = \(address(limitations.falseResultCopy))",
            "limitations.covered = \(covered)",
            "limitations.uncovered = \(uncovered)",
            "limitations.byteStatus = \(limitations.bytePreservation.status.rawValue)",
            "limitations.byteCopy = \(address(limitations.bytePreservation.limitationCopy))",
            "technical.onDevice = \(technical.onDeviceProcessing.rawValue)",
            "technical.integrityStatus = \(technical.integrity.status.rawValue)",
            "technical.verifiedArtifacts = \(technical.integrity.verifiedArtifactCount)",
            "technical.dimensions = \(dimensions)",
            "technical.unrecordedDimensions = \(unrecorded)",
            "technical.components = \(components)",
            "path.model-information = \(address(paths.modelInformation))",
            "path.privacy-behavior = \(address(paths.privacyBehavior))",
            "path.correction-channel = \(address(paths.correctionChannel))",
            "recovery = \(presentation.recovery.rawValue)",
        ]
    }

    /// The error screen, in a fixed field order.
    ///
    /// Requirements 11.18 and 4.17 give a failed session one category, one recovery, and no
    /// evidence, so the `evidenceReport`, `workProgress`, and `cancellation` lines exist to
    /// pin the three absences rather than to report a value.
    static func lines(of screen: AnalysisErrorScreen, on analysis: AnalysisScreen) -> [String] {
        let shortEdge: String
        if let edge = screen.inputQuality?.shortEdgeBeforeOrientation {
            shortEdge = "\(edge)"
        } else {
            shortEdge = "nil"
        }

        return [
            "family = \(analysis.family.rawValue)",
            "identity.session = \(screen.identity.sessionID.rawValue)",
            "identity.attempt = \(screen.identity.attemptGeneration)",
            "error.category = \(screen.presentation.error.rawValue)",
            "error.messageCopy = \(address(screen.presentation.messageCopy))",
            "error.recoveryCopy = \(address(screen.presentation.recoveryCopy))",
            "recovery = \(screen.recovery.rawValue)",
            "byteStatus = \(screen.bytePreservationStatus?.rawValue ?? "nil")",
            "shortEdge = \(shortEdge)",
            "evidenceReport = \(analysis.evidenceReport == nil ? "nil" : "present")",
            "workProgress = \(analysis.workProgress == nil ? "nil" : "present")",
            "cancellation = \(analysis.cancellation?.rawValue ?? "nil")",
        ]
    }

    /// One disclosure destination, in a fixed field order.
    static func lines(
        of screens: DisclosureScreens,
        kind: DisclosureScreenKind
    ) -> [String] {
        let destinations = RequiredDisclosureDestination.allCases
            .filter { $0.screen == kind }
            .map(\.rawValue)
            .joined(separator: ",")
        let blocked = DisclosureScreenSurfaces.recorded(for: kind)
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")

        return [
            "kind = \(kind.rawValue)",
            "statementCopy = \(address(screens.statementCopy(for: kind)))",
            "entryPath = \(kind.entryPath.rawValue)",
            "destinations = \(destinations)",
            "blockedSurfaces = \(blocked)",
        ]
    }

    /// The privacy screen's structural answers, in a fixed field order.
    static func lines(of privacy: PrivacyDisclosureScreen) -> [String] {
        let practices = privacy.absentDataPractices.map(\.rawValue).joined(separator: ",")
        let deadlines = privacy.cleanupDeadlines
            .map { "\($0.reason.rawValue)=\($0.deadline.milliseconds)" }
            .joined(separator: ",")
        let claims = privacy.accessClaims.map(\.rawValue).joined(separator: ",")
        let topics = privacy.coveredTopics.map(\.rawValue).joined(separator: ",")

        return [
            "explanationCopy = \(address(privacy.explanationCopy))",
            "pixelInference = \(privacy.pixelInference.rawValue)",
            "provenanceValidation = \(privacy.provenanceValidation.rawValue)",
            "photoAccess = \(privacy.photoAccess.rawValue)",
            "networkRequirement = \(privacy.networkRequirement.rawValue)",
            "modelDelivery = \(privacy.modelDelivery.rawValue)",
            "removalScope = \(privacy.removalScope.rawValue)",
            "topics = \(topics)",
            "absentDataPractices = \(practices)",
            "cleanupDeadlines = \(deadlines)",
            "accessClaims = \(claims)",
            "lifecyclePolicy = \(privacy.lifecyclePolicyID.rawValue)",
        ]
    }
}

/// Why a snapshot fixture could not produce the screen it was asked for.
///
/// A thrown failure rather than a recorded issue plus a substituted value: a snapshot built
/// from the wrong family would assert something about a screen nobody asked for.
enum SnapshotFixtureFailure: Error {
    case unexpectedFamily(AnalysisScreenFamily)
}

/// Which recorded copy gaps each disclosure screen claims.
///
/// A total switch over the screen vocabulary rather than four direct reads, so a new screen
/// kind does not compile until it says what it is blocked on.
enum DisclosureScreenSurfaces {
    static func recorded(for kind: DisclosureScreenKind) -> Set<UnapprovedDisclosureSurface> {
        switch kind {
        case .privacy: PrivacyDisclosureScreen.unapprovedSurfaces
        case .modelInformation: ModelInformationScreen.unapprovedSurfaces
        case .scopeAndLimitations: ScopeAndLimitationsScreen.unapprovedSurfaces
        case .correctionChannel: CorrectionChannelScreen.unapprovedSurfaces
        }
    }
}

// MARK: - Whole-aggregate anchors

// Three complete reports, written out field by field. Every other suite in this file checks
// one dimension across its whole vocabulary; these three check the *whole value* for three
// compositions, so a change to any field of any of them is a diff rather than a field nobody
// happened to assert.
//
// The three are chosen to be the three distinguishable report shapes: a pixel-only report
// with the provenance lane unavailable and no summary, a provenance-enabled report with no
// summary, and a fused report with a summary and an apparent-inconsistency notice.

@Suite("Whole completed reports, as written-out value snapshots")
struct CompletedReportAnchorSnapshotTests {

    /// The scope every Version 1 report states. Written out once and reused by all three
    /// anchors, because it is the same nine exclusions in every report (Requirement 8.10).
    static let uncoveredScopes = """
        limitations.uncovered = localizedEdit,composite,vaeReconstruction,video,audio,\
        animatedMedia,additionalStaticFormat,additionalIngestRoute,multipleImages
        """

    /// The six bound component versions the synthetic session binding carries
    /// (Requirements 4.12, 8.12, and 10.18).
    static let components = """
        technical.components = model-bundle=bundle.synthetic,\
        model-checkpoint=checkpoint.synthetic,core-ml-model=component.coreml.synthetic,\
        preprocessing-contract=contract.preprocessing.synthetic,\
        calibration-policy=policy.calibration.synthetic,\
        verdict-copy-compatibility=copy.compatibility.v1
        """

    @Test("A pixel-only report projects exactly this value")
    func pixelOnlyReportSnapshot() throws {
        let presentation = try ReportFixture.pixelOnlyPresentation()

        #expect(
            PresentationSnapshot.lines(of: presentation) == [
                "identity.session = session.synthetic",
                "identity.attempt = 1",
                "pixel.evidence = noStrongSignalDetected",
                "pixel.fixedText = No strong signal detected",
                "pixel.labelCopy = pixel-label/no-strong-signal-detected",
                "pixel.explanationCopy = pixel-explanation/no-strong-signal-detected",
                // Requirements 6.4, 6.20, and 8.8: the lane is unavailable, which is a fact
                // about the installed release and not one of the five enabled states.
                "provenance.state = unavailable/validatorNotCompiledIntoRelease",
                "provenance.distinction = release-cannot-validate",
                "provenance.stateCopy = provenance-unavailable",
                "provenance.claimBinding = not-applicable",
                "provenance.screenshot = not-applicable",
                "apparentInconsistency = none",
                // Requirement 7.10: an unavailable lane is outside the fifteen combinations
                // and always omits the summary.
                "combinedSummary = omitted/provenance-lane-unavailable",
                "limitations.scopeCopy = evidence-scope",
                "limitations.falseResultCopy = false-result-limitation",
                "limitations.covered = wholeImageSynthesis",
                Self.uncoveredScopes,
                "limitations.byteStatus = originalBytes",
                "limitations.byteCopy = byte-preservation-limitation/original-bytes",
                "technical.onDevice = all-processing-on-device",
                "technical.integrityStatus = verified",
                "technical.verifiedArtifacts = 1",
                "technical.dimensions = decoded-width=1024,decoded-height=768,short-edge=768",
                "technical.unrecordedDimensions = ",
                Self.components,
                "path.model-information = model-information",
                "path.privacy-behavior = privacy-explanation",
                "path.correction-channel = correction-channel",
                "recovery = selectAnotherImage",
            ]
        )
    }

    @Test("A provenance-enabled report with no summary projects exactly this value")
    func provenanceReportSnapshot() throws {
        let presentation = try ReportFixture.provenancePresentation(lane: .available(.absent))

        #expect(
            PresentationSnapshot.lines(of: presentation) == [
                "identity.session = session.synthetic",
                "identity.attempt = 1",
                "pixel.evidence = signalsConsistentWithAIGeneration",
                "pixel.fixedText = Signals consistent with AI generation",
                "pixel.labelCopy = pixel-label/signals-consistent-with-ai-generation",
                "pixel.explanationCopy = pixel-explanation/signals-consistent-with-ai-generation",
                "provenance.state = available/absent",
                "provenance.distinction = enabled-validator-result",
                "provenance.stateCopy = provenance-state/absent",
                "provenance.claimBinding = not-applicable",
                // Requirement 6.16, satisfied for a superset: see
                // `theScreenshotExplanationIsShownForEveryAbsentResult` below.
                "provenance.screenshot = shown-for-absent-credential/screenshot-provenance-explanation",
                "apparentInconsistency = none",
                // Requirements 7.9 and 7.16: this release binds no fusion rule at all.
                "combinedSummary = omitted/no-approved-summary-for-this-combination",
                "limitations.scopeCopy = evidence-scope",
                "limitations.falseResultCopy = false-result-limitation",
                "limitations.covered = wholeImageSynthesis",
                Self.uncoveredScopes,
                "limitations.byteStatus = originalBytes",
                "limitations.byteCopy = byte-preservation-limitation/original-bytes",
                "technical.onDevice = all-processing-on-device",
                "technical.integrityStatus = verified",
                "technical.verifiedArtifacts = 1",
                "technical.dimensions = decoded-width=1024,decoded-height=768,short-edge=768",
                "technical.unrecordedDimensions = ",
                Self.components,
                "path.model-information = model-information",
                "path.privacy-behavior = privacy-explanation",
                "path.correction-channel = correction-channel",
                "recovery = selectAnotherImage",
            ]
        )
    }

    @Test("A fused report with a summary and a contradiction projects exactly this value")
    func fusedReportSnapshot() throws {
        let presentation = try ReportFixture.fusedPresentation()

        #expect(
            PresentationSnapshot.lines(of: presentation) == [
                "identity.session = session.synthetic",
                "identity.attempt = 1",
                "pixel.evidence = signalsConsistentWithAIGeneration",
                "pixel.fixedText = Signals consistent with AI generation",
                "pixel.labelCopy = pixel-label/signals-consistent-with-ai-generation",
                "pixel.explanationCopy = pixel-explanation/signals-consistent-with-ai-generation",
                // Requirement 7.13: both lanes are retained alongside the summary.
                "provenance.state = available/absent",
                "provenance.distinction = enabled-validator-result",
                "provenance.stateCopy = provenance-state/absent",
                "provenance.claimBinding = not-applicable",
                "provenance.screenshot = shown-for-absent-credential/screenshot-provenance-explanation",
                // Requirement 7.8: the contradiction is identified beside both cards.
                "apparentInconsistency = declared/apparent-inconsistency",
                // Requirement 7.11: a shown summary names the rule version that produced it.
                // The summary surface is addressed by the key the fusion rule emitted, which
                // is why the synthetic rule's key appears inside the surface identifier.
                """
                combinedSummary = shown/combined-summary/\
                copy.summary.signals-consistent-with-ai-generation/rule=rule.fusion.synthetic
                """,
                "limitations.scopeCopy = evidence-scope",
                "limitations.falseResultCopy = false-result-limitation",
                "limitations.covered = wholeImageSynthesis",
                Self.uncoveredScopes,
                "limitations.byteStatus = unknown",
                "limitations.byteCopy = byte-preservation-limitation/unknown",
                "technical.onDevice = all-processing-on-device",
                "technical.integrityStatus = verified",
                "technical.verifiedArtifacts = 1",
                "technical.dimensions = decoded-width=1024,decoded-height=768,short-edge=768",
                "technical.unrecordedDimensions = ",
                Self.components,
                "path.model-information = model-information",
                "path.privacy-behavior = privacy-explanation",
                "path.correction-channel = correction-channel",
                "recovery = selectAnotherImage",
            ]
        )
    }

    @Test("Assembling the same screen twice produces the same snapshot")
    func assemblySnapshotIsDeterministic() throws {
        // `EvidenceReportPresentation.assembling` is asserted pure elsewhere; what is
        // asserted here is that the *rendering* this file snapshots is too, so a passing
        // snapshot cannot depend on iteration order inside a set or dictionary.
        let screen = try ReportFixture.provenanceScreen(lane: ReportFixture.availableLane(.validated))
        let copy = try ReportFixture.provenanceBinding()

        let first = try EvidenceReportPresentation.assembling(screen, copy: copy)
        let second = try EvidenceReportPresentation.assembling(screen, copy: copy)

        #expect(first == second)
        #expect(PresentationSnapshot.lines(of: first) == PresentationSnapshot.lines(of: second))
    }

    @Test("Every anchor snapshot has the same field set, in the same order")
    func anchorsShareOneFieldOrder() throws {
        // A snapshot whose field set varies by case is a snapshot that can lose a field
        // silently. The renderer is total over the presentation, so every case has to
        // produce the same left-hand sides.
        let fields = try [
            ReportFixture.pixelOnlyPresentation(),
            ReportFixture.provenancePresentation(lane: .available(.absent)),
            ReportFixture.fusedPresentation(),
        ].map { presentation in
            PresentationSnapshot.lines(of: presentation).map { line in
                String(line.prefix(while: { $0 != "=" })).trimmingCharacters(in: .whitespaces)
            }
        }

        #expect(fields[0] == fields[1])
        #expect(fields[1] == fields[2])
        #expect(fields[0].count == 29)
        #expect(Set(fields[0]).count == 29)
    }
}

// MARK: - 8.2, 8.3, 8.4, 8.5: the three pixel labels

@Suite("Pixel labels, one snapshot per label")
struct PixelLaneSnapshotTests {

    /// One label's projected snapshot, written out.
    ///
    /// `text` is the display string Requirement 8.2 fixes character for character,
    /// transcribed as a literal rather than read back from ``FixedPixelLabelText``: asking
    /// the type under test what its own value is asserts nothing.
    struct Expectation: Sendable {
        let evidence: PixelEvidence
        let text: String
        let labelCopy: String
        let explanationCopy: String
    }

    static let expectations: [Expectation] = [
        Expectation(
            evidence: .signalsConsistentWithAIGeneration,
            text: "Signals consistent with AI generation",
            labelCopy: "pixel-label/signals-consistent-with-ai-generation",
            explanationCopy: "pixel-explanation/signals-consistent-with-ai-generation"
        ),
        Expectation(
            evidence: .noStrongSignalDetected,
            text: "No strong signal detected",
            labelCopy: "pixel-label/no-strong-signal-detected",
            explanationCopy: "pixel-explanation/no-strong-signal-detected"
        ),
        Expectation(
            evidence: .notEnoughSignal,
            text: "Not enough signal",
            labelCopy: "pixel-label/not-enough-signal",
            explanationCopy: "pixel-explanation/not-enough-signal"
        ),
    ]

    @Test("The table covers the whole label vocabulary and nothing else")
    func tableIsExhaustive() {
        // Requirement 8.2 fixes exactly three labels. The table growing or shrinking without
        // the vocabulary doing the same is the failure this catches.
        #expect(Self.expectations.count == 3)
        #expect(PixelEvidence.allCases.count == 3)
        #expect(Set(Self.expectations.map(\.evidence)) == Set(PixelEvidence.allCases))
        #expect(Set(Self.expectations.map(\.text)).count == 3)
        #expect(Set(Self.expectations.map(\.text)) == FixedPixelLabelText.allTexts)
    }

    @Test("Each label projects exactly its snapshot", arguments: PixelLaneSnapshotTests.expectations)
    func labelSnapshot(expected: Expectation) throws {
        let card = try ReportFixture.pixelOnlyPresentation(pixel: expected.evidence).cards.pixel

        #expect(card.evidence == expected.evidence)
        #expect(card.fixedLabelText.value == expected.text)
        #expect(card.lane.fixedLabelText.value == expected.text)
        #expect(PresentationSnapshot.address(card.lane.labelCopy) == expected.labelCopy)
        #expect(PresentationSnapshot.address(card.lane.explanationCopy) == expected.explanationCopy)
    }

    @Test(
        "Each label's copy is addressed through the bound catalogue, not a literal",
        arguments: PixelLaneSnapshotTests.expectations
    )
    func labelCopyComesFromTheBinding(expected: Expectation) throws {
        // The snapshot above pins the *surface*, which is domain-owned. This pins the other
        // half: the localization key is the key the bound catalogue approved for that
        // surface, and the reference names the catalogue and compatibility identifier the
        // session agreed on (Requirement 8.1).
        let binding = try ViewStateFixture.pixelOnlyBinding()
        let card = try ReportFixture.pixelOnlyPresentation(pixel: expected.evidence).cards.pixel
        let key = expected.evidence.labelKey

        #expect(
            card.lane.labelCopy.localizationKey
                == CopyFixture.localizationKey(for: .pixelLabel(key))
        )
        #expect(
            card.lane.explanationCopy.localizationKey
                == CopyFixture.localizationKey(for: .pixelExplanation(key))
        )
        #expect(card.lane.labelCopy.catalogID == binding.catalogID)
        #expect(card.lane.labelCopy.compatibilityID == binding.compatibilityID)
    }

    @Test("No fixed label string carries a magnitude reading")
    func noLabelReadsAsAMagnitude() {
        // Requirement 8.13 removes numeric, percentage, and categorical confidence readings
        // from every user-facing surface. Checked on the transcribed literals rather than on
        // the type's own values, so a changed literal here is caught by `labelSnapshot` and a
        // changed *value* is caught by this.
        for expected in Self.expectations {
            let hasDigit = expected.text.contains { $0.isNumber }
            #expect(hasDigit == false, "\(expected.evidence)")
            #expect(expected.text.contains("%") == false, "\(expected.evidence)")
            let lowered = expected.text.lowercased()
            for fragment in ["probab", "confidence", "percent", "likel", "chance", "certain"] {
                #expect(lowered.contains(fragment) == false, "\(expected.evidence)")
            }
        }
    }
}

// MARK: - 6.4, 6.5, 6.9, 6.15-6.21, 7.3, 8.7, 8.8: the seven lane states

@Suite("Provenance lane states, one snapshot per state")
struct ProvenanceLaneSnapshotTests {

    /// One lane state's projected snapshot, written out.
    struct Expectation: Sendable {
        let name: String
        let lane: ProvenanceLane
        let state: String
        let distinction: String
        let stateCopy: String
        let claimBinding: String
        let screenshot: String
        /// Requirement 7.9, 7.10, or 7.16: why this lane state shows no Combined Summary in a
        /// release that binds no fusion rule.
        let summary: String
    }

    /// The two unavailable reasons and the five enabled categories.
    ///
    /// Built through ``ReportFixture/availableLane(_:)`` so the payloads are the same values
    /// every other suite in this target uses, which is what lets the coverage check below
    /// compare against ``ReportFixture/allLanes`` rather than restating it.
    static let expectations: [Expectation] = [
        Expectation(
            name: "unavailable/validator-not-compiled",
            lane: .unavailable(.validatorNotCompiledIntoRelease),
            state: "unavailable/validatorNotCompiledIntoRelease",
            distinction: "release-cannot-validate",
            stateCopy: "provenance-unavailable",
            claimBinding: "not-applicable",
            screenshot: "not-applicable",
            summary: "omitted/provenance-lane-unavailable"
        ),
        Expectation(
            name: "unavailable/capability-not-enabled",
            lane: .unavailable(.capabilityNotEnabledByReleaseCapabilityManifest),
            state: "unavailable/capabilityNotEnabledByReleaseCapabilityManifest",
            distinction: "release-cannot-validate",
            stateCopy: "provenance-unavailable",
            claimBinding: "not-applicable",
            screenshot: "not-applicable",
            summary: "omitted/provenance-lane-unavailable"
        ),
        Expectation(
            name: "validated",
            lane: ReportFixture.availableLane(.validated),
            state: "available/validated",
            distinction: "enabled-validator-result",
            stateCopy: "provenance-state/validated",
            // Requirement 6.17: the binding statement is the state's own approved copy, so a
            // validated card cannot carry a second, differently worded claim.
            claimBinding: "validated-claim-binding/provenance-state/validated",
            screenshot: "not-applicable",
            summary: "omitted/no-approved-summary-for-this-combination"
        ),
        Expectation(
            name: "invalid",
            lane: ReportFixture.availableLane(.invalid),
            state: "available/invalid",
            distinction: "enabled-validator-result",
            stateCopy: "provenance-state/invalid",
            claimBinding: "not-applicable",
            screenshot: "not-applicable",
            summary: "omitted/no-approved-summary-for-this-combination"
        ),
        Expectation(
            name: "absent",
            lane: ReportFixture.availableLane(.absent),
            state: "available/absent",
            distinction: "enabled-validator-result",
            stateCopy: "provenance-state/absent",
            claimBinding: "not-applicable",
            screenshot: "shown-for-absent-credential/screenshot-provenance-explanation",
            summary: "omitted/no-approved-summary-for-this-combination"
        ),
        Expectation(
            name: "unsupported",
            lane: ReportFixture.availableLane(.unsupported),
            state: "available/unsupported",
            distinction: "enabled-validator-result",
            stateCopy: "provenance-state/unsupported",
            claimBinding: "not-applicable",
            screenshot: "not-applicable",
            summary: "omitted/no-approved-summary-for-this-combination"
        ),
        Expectation(
            name: "indeterminate",
            lane: ReportFixture.availableLane(.indeterminate),
            state: "available/indeterminate",
            // Requirement 6.21: an enabled validator that could not conclude, distinct from
            // the unavailable lane above.
            distinction: "enabled-validator-inconclusive",
            stateCopy: "provenance-state/indeterminate",
            claimBinding: "not-applicable",
            screenshot: "not-applicable",
            summary: "omitted/no-approved-summary-for-this-combination"
        ),
    ]

    @Test("The table is the whole lane vocabulary: two unavailable reasons and five states")
    func tableIsExhaustive() {
        #expect(UnavailableReason.allCases.count == 2)
        #expect(ProvenanceCategory.allCases.count == 5)
        #expect(Self.expectations.count == 7)
        #expect(
            Self.expectations.count
                == UnavailableReason.allCases.count + ProvenanceCategory.allCases.count
        )
        #expect(Set(Self.expectations.map(\.lane)) == Set(ReportFixture.allLanes))
        #expect(Set(Self.expectations.map(\.name)).count == 7)
        // Every state's approved copy address is distinct, so no two lane states can be
        // described by the same sentence (Requirements 6.9 and 8.8).
        #expect(Set(Self.expectations.map(\.stateCopy)).count == 6)
    }

    @Test(
        "Each lane state projects exactly its snapshot",
        arguments: ProvenanceLaneSnapshotTests.expectations
    )
    func laneSnapshot(expected: Expectation) throws {
        let presentation = try ReportFixture.provenancePresentation(lane: expected.lane)
        let card = presentation.cards.provenance

        #expect(PresentationSnapshot.laneState(card.state) == expected.state, "\(expected.name)")
        #expect(card.distinction.rawValue == expected.distinction, "\(expected.name)")
        #expect(
            PresentationSnapshot.address(card.lane.stateCopy) == expected.stateCopy,
            "\(expected.name)"
        )
        #expect(
            PresentationSnapshot.claimBinding(card.claimBinding) == expected.claimBinding,
            "\(expected.name)"
        )
        #expect(
            PresentationSnapshot.screenshot(card.screenshotExplanation) == expected.screenshot,
            "\(expected.name)"
        )
        #expect(
            PresentationSnapshot.summary(presentation.combinedSummary) == expected.summary,
            "\(expected.name)"
        )
        // Requirements 7.2 and 7.3: both cards, for every lane state, always.
        #expect(presentation.cards.pixel.evidence == .signalsConsistentWithAIGeneration)
    }

    @Test("The unavailable lane is never described as one of the five enabled states")
    func unavailableIsNotAnEnabledState() throws {
        // Requirement 8.8 as a snapshot over both reasons: the state is the `unavailable`
        // case, the distinction says the release cannot validate, and the approved address is
        // the unavailable surface rather than any `provenance-state/...` surface.
        for reason in UnavailableReason.allCases {
            let card = try ReportFixture.provenancePresentation(lane: .unavailable(reason))
                .cards.provenance
            #expect(card.state == .unavailable(reason), "\(reason)")
            #expect(card.distinction == .releaseCannotValidate, "\(reason)")
            #expect(card.lane.stateCopy.surface == VerdictCopySurface.provenanceUnavailable, "\(reason)")
            let addressesAnEnabledState = ProvenanceStateKey.allCases.contains {
                card.lane.stateCopy.surface == .provenanceState($0)
            }
            #expect(addressesAnEnabledState == false, "\(reason)")
        }
    }

    @Test("The screenshot explanation is shown for every absent result, which is a superset")
    func theScreenshotExplanationIsShownForEveryAbsentResult() throws {
        // Requirement 6.16 names screenshots specifically. Nothing in this application
        // records whether an image is a screenshot, so the approved explanation is attached
        // to *every* enabled `absent` result. That is the superset, and it is what is
        // asserted here - narrowing it needs the missing input, not different wording.
        for expected in Self.expectations {
            let card = try ReportFixture.provenancePresentation(lane: expected.lane)
                .cards.provenance
            let shown = card.screenshotExplanation != .notApplicable
            #expect(shown == (expected.lane.category == .absent), "\(expected.name)")
        }

        // The missing input is recorded rather than assumed, and it names the requirement it
        // would narrow.
        #expect(UnavailableEvidenceInput.allCases.count == 1)
        #expect(UnavailableEvidenceInput.screenshotOriginDetermination.narrows == "6.16")
    }

    @Test("A binding statement is carried by exactly the validated state")
    func onlyValidatedCarriesABindingStatement() throws {
        for expected in Self.expectations {
            let card = try ReportFixture.provenancePresentation(lane: expected.lane)
                .cards.provenance
            let carries = card.claimBinding != .notApplicable
            #expect(carries == (expected.lane.category == .validated), "\(expected.name)")
        }
    }

    @Test("The three distinctions partition the seven lane states exactly")
    func distinctionsPartitionTheVocabulary() throws {
        var byDistinction: [ProvenanceLaneDistinction: [String]] = [:]
        for expected in Self.expectations {
            let card = try ReportFixture.provenancePresentation(lane: expected.lane)
                .cards.provenance
            byDistinction[card.distinction, default: []].append(expected.name)
        }

        #expect(ProvenanceLaneDistinction.allCases.count == 3)
        #expect(byDistinction[.releaseCannotValidate]?.count == 2)
        #expect(byDistinction[.enabledValidatorResult]?.count == 4)
        #expect(byDistinction[.enabledValidatorInconclusive]?.count == 1)
        #expect(Set(byDistinction.keys) == Set(ProvenanceLaneDistinction.allCases))
    }
}

// MARK: - 7.4, 7.5, 7.8: the two lanes do not influence each other

@Suite("The two lanes are projected independently across the whole cross product")
struct LaneIndependenceSnapshotTests {

    @Test("Every label crossed with every lane state keeps both snapshots unchanged")
    func laneSnapshotsAreIndependent() throws {
        // Requirements 7.4 and 7.5 keep each analyzer from changing the other's result, and
        // Requirement 7.8 keeps a presented contradiction from suppressing or ranking either
        // lane. Here that is a reducer property over all twenty-one combinations: the
        // `pixel.*` lines depend only on the label and the `provenance.*` lines only on the
        // lane, so neither can shift when the other changes.
        var pixelLinesByLabel: [PixelEvidence: [String]] = [:]
        var provenanceLinesByLane: [ProvenanceLane: [String]] = [:]
        var combinations = 0

        for evidence in PixelEvidence.allCases {
            for lane in ReportFixture.allLanes {
                let presentation = try ReportFixture.provenancePresentation(
                    pixel: evidence,
                    lane: lane
                )
                let lines = PresentationSnapshot.lines(of: presentation)
                let pixelLines = lines.filter { $0.hasPrefix("pixel.") }
                let provenanceLines = lines.filter { $0.hasPrefix("provenance.") }

                #expect(pixelLines.count == 4)
                #expect(provenanceLines.count == 5)

                if let known = pixelLinesByLabel[evidence] {
                    #expect(known == pixelLines, "\(evidence)")
                } else {
                    pixelLinesByLabel[evidence] = pixelLines
                }
                if let known = provenanceLinesByLane[lane] {
                    #expect(known == provenanceLines, "\(lane)")
                } else {
                    provenanceLinesByLane[lane] = provenanceLines
                }
                combinations += 1
            }
        }

        #expect(combinations == 21)
        #expect(pixelLinesByLabel.count == 3)
        #expect(provenanceLinesByLane.count == 7)
        // No two labels and no two lane states project the same lines, so the independence
        // above is not independence by everything being identical.
        #expect(Set(pixelLinesByLabel.values.map { $0.joined(separator: "\n") }).count == 3)
        #expect(Set(provenanceLinesByLane.values.map { $0.joined(separator: "\n") }).count == 7)
    }

    @Test("Both cards exist for all twenty-one combinations")
    func bothCardsAlwaysExist() throws {
        // `EvidenceCardPair` has two non-optional members of two different types, so this
        // cannot fail without the type changing. Asserted over the whole cross product anyway,
        // because Requirements 7.2 and 7.3 say "every completed Evidence Report".
        var checked = 0
        for evidence in PixelEvidence.allCases {
            for lane in ReportFixture.allLanes {
                let cards = try ReportFixture.provenancePresentation(pixel: evidence, lane: lane)
                    .cards
                #expect(cards.pixel.evidence == evidence)
                #expect(PresentationSnapshot.laneState(cards.provenance.state).isEmpty == false)
                let labels = Mirror(reflecting: cards).children.compactMap(\.label)
                #expect(labels == ["pixel", "provenance"])
                checked += 1
            }
        }
        #expect(checked == 21)
    }
}

// MARK: - 6.15, 8.12: the three byte preservation statuses

@Suite("Byte preservation statuses, one snapshot per status")
struct BytePreservationSnapshotTests {

    struct Expectation: Sendable {
        let status: BytePreservationStatus
        let limitationCopy: String
        /// Whether Requirement 6.15 names this status explicitly.
        let namedByRequirement: Bool
    }

    static let expectations: [Expectation] = [
        Expectation(
            status: .originalBytes,
            limitationCopy: "byte-preservation-limitation/original-bytes",
            namedByRequirement: false
        ),
        Expectation(
            status: .platformTransformedCopy,
            limitationCopy: "byte-preservation-limitation/platform-transformed-copy",
            namedByRequirement: true
        ),
        Expectation(
            status: .unknown,
            limitationCopy: "byte-preservation-limitation/unknown",
            namedByRequirement: true
        ),
    ]

    @Test("The table covers the whole status vocabulary")
    func tableIsExhaustive() {
        #expect(BytePreservationStatus.allCases.count == 3)
        #expect(BytePreservationStatusKey.allCases.count == 3)
        #expect(Self.expectations.count == 3)
        #expect(Set(Self.expectations.map(\.status)) == Set(BytePreservationStatus.allCases))
        #expect(Set(Self.expectations.map(\.limitationCopy)).count == 3)
        // Requirement 6.15 names exactly the transformed and unknown statuses.
        let named = Self.expectations.filter(\.namedByRequirement).map(\.status)
        #expect(named == [.platformTransformedCopy, .unknown])
    }

    @Test(
        "Each status projects exactly its snapshot",
        arguments: BytePreservationSnapshotTests.expectations
    )
    func statusSnapshot(expected: Expectation) throws {
        let limitations = try ReportFixture.pixelOnlyPresentation(
            bytePreservationStatus: expected.status
        ).limitations

        #expect(limitations.bytePreservation.status == expected.status)
        #expect(
            PresentationSnapshot.address(limitations.bytePreservation.limitationCopy)
                == expected.limitationCopy
        )
        #expect(
            limitations.bytePreservation.isNamedByTransformedOrUnknownRequirement
                == expected.namedByRequirement
        )
        // Requirement 6.15 is attached unconditionally: there is no status for which the
        // limitation is dropped, so every status resolves the surface for its own key.
        #expect(
            limitations.bytePreservation.limitationCopy.surface
                == .bytePreservationLimitation(expected.status.statusKey)
        )
        // The scope and false-result statements are unaffected by the byte status
        // (Requirements 8.10 and 8.11).
        #expect(PresentationSnapshot.address(limitations.scopeCopy) == "evidence-scope")
        #expect(
            PresentationSnapshot.address(limitations.falseResultCopy)
                == "false-result-limitation"
        )
        #expect(limitations.statesEveryRequiredScope)
    }

    @Test("Changing the status changes exactly the byte-status lines")
    func onlyTheByteLinesChange() throws {
        // A reducer check: the byte status is one input, and it may not move any other field.
        var byStatus: [BytePreservationStatus: [String]] = [:]
        for status in BytePreservationStatus.allCases {
            let lines = PresentationSnapshot.lines(
                of: try ReportFixture.pixelOnlyPresentation(bytePreservationStatus: status)
            )
            byStatus[status] = lines
        }

        let reference = try #require(byStatus[.originalBytes])
        for status in BytePreservationStatus.allCases where status != .originalBytes {
            let lines = try #require(byStatus[status])
            #expect(lines.count == reference.count, "\(status)")
            let differing = zip(reference, lines).filter { $0.0 != $0.1 }.map(\.1)
            #expect(differing.count == 2, "\(status)")
            let onlyByteLines = differing.allSatisfy { $0.hasPrefix("limitations.byte") }
            #expect(onlyByteLines, "\(status)")
        }
    }
}

// MARK: - 7.8: an apparent contradiction

@Suite("Apparent inconsistency, declared and undeclared")
struct ApparentInconsistencySnapshotTests {

    @Test("A declared notice projects exactly this value")
    func declaredSnapshot() throws {
        let presentation = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.validated),
            inconsistent: true
        )

        #expect(
            PresentationSnapshot.inconsistency(presentation.apparentInconsistency)
                == "declared/apparent-inconsistency"
        )
        let reference = try #require(presentation.apparentInconsistency.reference)
        #expect(reference.surface == VerdictCopySurface.apparentInconsistency)
    }

    @Test("An undeclared notice projects the stated absence rather than nothing")
    func undeclaredSnapshot() throws {
        let presentation = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.validated),
            inconsistent: false
        )

        #expect(PresentationSnapshot.inconsistency(presentation.apparentInconsistency) == "none")
        #expect(presentation.apparentInconsistency == .none)
        #expect(presentation.apparentInconsistency.reference == nil)
    }

    @Test("Declaring a contradiction changes exactly one line of the snapshot")
    func onlyTheNoticeLineChanges() throws {
        // Requirement 7.8: both source-lane results are retained and neither is suppressed,
        // overridden, or ranked. As a reducer property that is precisely "one line moves":
        // the notice appears, and no card, limitation, transparency field, summary, or path
        // line changes with it.
        let lane = ReportFixture.availableLane(.validated)
        let quiet = PresentationSnapshot.lines(
            of: try ReportFixture.provenancePresentation(lane: lane, inconsistent: false)
        )
        let noticed = PresentationSnapshot.lines(
            of: try ReportFixture.provenancePresentation(lane: lane, inconsistent: true)
        )

        #expect(quiet.count == noticed.count)
        let differing = zip(quiet, noticed).filter { $0.0 != $0.1 }.map(\.1)
        #expect(differing == ["apparentInconsistency = declared/apparent-inconsistency"])
    }

    @Test("Both notice answers are reachable and there is no third")
    func theNoticeVocabularyIsClosed() throws {
        // `ApparentInconsistencyNotice` is not `CaseIterable` - its declared case carries a
        // payload - so exhaustiveness is asserted by reaching both answers and pinning that a
        // total switch over them produces two distinct renderings.
        let lane = ReportFixture.availableLane(.invalid)
        let rendered = try [false, true].map { flag in
            PresentationSnapshot.inconsistency(
                try ReportFixture.provenancePresentation(lane: lane, inconsistent: flag)
                    .apparentInconsistency
            )
        }
        #expect(rendered == ["none", "declared/apparent-inconsistency"])
    }
}

// MARK: - 7.9-7.17: the Combined Summary, shown and omitted

@Suite("Combined Summary, shown and both omission reasons")
struct CombinedSummarySnapshotTests {

    @Test("Both omission reasons are reached, and there are exactly two")
    func bothOmissionReasonsAreReached() throws {
        #expect(FusionOmissionReason.allCases.count == 2)

        // Requirement 7.10: an unavailable lane is outside the fifteen combinations.
        let unavailable = try ReportFixture.pixelOnlyPresentation()
        #expect(
            PresentationSnapshot.summary(unavailable.combinedSummary)
                == "omitted/provenance-lane-unavailable"
        )

        // Requirements 7.9 and 7.16: both lanes available, and this release binds no rule.
        var reached: Set<FusionOmissionReason> = [.provenanceLaneUnavailable]
        for category in ProvenanceCategory.allCases {
            let presentation = try ReportFixture.provenancePresentation(
                lane: ReportFixture.availableLane(category)
            )
            #expect(
                PresentationSnapshot.summary(presentation.combinedSummary)
                    == "omitted/no-approved-summary-for-this-combination",
                "\(category)"
            )
            reached.insert(.noApprovedSummaryForThisCombination)
        }
        #expect(reached == Set(FusionOmissionReason.allCases))
    }

    @Test("Every shown summary names its rule version and its own approved surface")
    func shownSummarySnapshots() throws {
        // One shown summary per pixel label, because the synthetic rule emits one key per
        // label. Requirement 7.11: the summary is identified as a Combined Summary and the
        // rule version is displayed with it.
        var addresses: [String] = []
        for evidence in PixelEvidence.allCases {
            let presentation = try ReportFixture.fusedPresentation(pixel: evidence)
            let summary = try #require(presentation.combinedSummary.summary)
            #expect(summary.fusionRuleID == CopyFixture.fusionRuleID)
            #expect(summary.fusionRuleID.rawValue == "rule.fusion.synthetic")
            let ruleKey = try #require(CopyFixture.summaryKeys[evidence.labelKey])
            #expect(summary.summaryCopy.surface == .combinedSummary(ruleKey))
            addresses.append(PresentationSnapshot.address(summary.summaryCopy))
        }

        #expect(
            addresses == [
                "combined-summary/copy.summary.signals-consistent-with-ai-generation",
                "combined-summary/copy.summary.no-strong-signal-detected",
                "combined-summary/copy.summary.not-enough-signal",
            ]
        )
    }

    @Test("A shown summary suppresses no card, no limitation, and no path")
    func aShownSummarySuppressesNothing() throws {
        // Requirements 7.13 and 7.17: both immutable lane fields and the limitations of both
        // lanes survive the summary. As a snapshot: every line that is not the summary line
        // still has a value, and both cards are still the report's own lanes.
        for evidence in PixelEvidence.allCases {
            let presentation = try ReportFixture.fusedPresentation(pixel: evidence)
            let lines = PresentationSnapshot.lines(of: presentation)

            #expect(lines.count == 29, "\(evidence)")
            #expect(presentation.cards.pixel.evidence == evidence, "\(evidence)")
            #expect(presentation.cards.provenance.state == .available(.absent), "\(evidence)")
            #expect(presentation.limitations.statesEveryRequiredScope, "\(evidence)")
            let emptyValues = lines.filter { $0.hasSuffix("= ") }
            // Only the unrecorded-dimension line is legitimately empty: this session recorded
            // every dimension, so there is nothing to list.
            #expect(emptyValues == ["technical.unrecordedDimensions = "], "\(evidence)")
        }
    }

    @Test("The summary section holds a summary or a reason, and never a lane")
    func theSectionCarriesNoLane() throws {
        // Requirement 7.13: the summary sits beside the cards rather than in place of either,
        // so the section itself has no lane member to carry one.
        let shown = try ReportFixture.fusedPresentation().combinedSummary
        let omitted = try ReportFixture.pixelOnlyPresentation().combinedSummary

        #expect(shown.summary != nil)
        #expect(shown.fusionRuleID == CopyFixture.fusionRuleID)
        #expect(omitted.summary == nil)
        #expect(omitted.fusionRuleID == nil)

        let summary = try #require(shown.summary)
        let members = Mirror(reflecting: summary).children.compactMap(\.label)
        #expect(members == ["summaryCopy", "fusionRuleID"])
    }

    @Test("A fusion-enabled release reaches exactly three summary surfaces")
    func reachableSummarySurfacesAreTheRuleSOwn() throws {
        // Requirement 7.12 requires a behaviour, including explicit omission, for each of the
        // fifteen combinations. The presentation-side consequence is that the reachable
        // summary surfaces are exactly the keys the bound rule shows, so a summary from a rule
        // this release does not bind cannot appear.
        let binding = try ViewStateFixture.fusionBinding()
        let reachable = binding.reachableSurfaces

        #expect(reachable.isFusionEnabled)
        #expect(reachable.isProvenanceEnabled)
        #expect(reachable.combinedSummaryKeys == Set(CopyFixture.summaryKeys.values))
        #expect(reachable.combinedSummaryKeys.count == 3)
        #expect(FusionLaneCombination.allCombinations.count == 15)
    }
}

// MARK: - 11.17, 11.18, 4.17: the ten Analysis Errors and their recovery

@Suite("Analysis Errors, one snapshot per category and preservation shape")
struct AnalysisErrorSnapshotTests {

    /// The ten category names Requirement 11.17's closed set fixes, transcribed as literals.
    ///
    /// In declaration order, which is the order every projection and audit iterates.
    static let categoryNames = [
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

    /// One projected error screen and the analysis screen it came from.
    static func project(
        _ error: AnalysisError,
        preserving: Bool
    ) throws -> (AnalysisScreen, AnalysisErrorScreen) {
        // Constructed directly rather than through `ViewStateFixture.failure`, because that
        // fixture substitutes a quality record for a `nil` one and the unrecorded shape is
        // exactly what Requirement 3.14 distinguishes.
        let failure = try #require(
            AnalysisFailureSnapshot(
                sessionID: ViewStateFixture.sessionID(),
                error: error,
                stage: .inputValidation,
                bytePreservationStatus: preserving ? .platformTransformedCopy : nil,
                inputQuality: preserving ? ViewStateFixture.quality() : nil
            )
        )
        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.ended(outcome: .failed(failure))
        )
        guard case let .error(errorScreen) = screen else {
            throw SnapshotFixtureFailure.unexpectedFamily(screen.family)
        }
        return (screen, errorScreen)
    }

    @Test("The transcribed category list is the whole vocabulary, in declaration order")
    func categoryListIsExhaustive() {
        #expect(AnalysisError.allCases.count == 10)
        #expect(AnalysisErrorKey.allCases.count == 10)
        #expect(Self.categoryNames.count == 10)
        #expect(AnalysisError.allCases.map(\.rawValue) == Self.categoryNames)
        #expect(AnalysisErrorKey.allCases.map(\.rawValue) == Self.categoryNames)
        #expect(Set(Self.categoryNames).count == 10)
    }

    @Test(
        "Each category projects exactly one category, one recovery, and no evidence",
        arguments: AnalysisError.allCases
    )
    func errorSnapshotWithPreservedMeasurements(error: AnalysisError) throws {
        let (analysis, screen) = try Self.project(error, preserving: true)

        // Requirement 11.18: exactly one category and a recovery action, with no Pixel
        // Evidence, Provenance Evidence, or Combined Summary. The last three are pinned as
        // `nil` lines rather than as an absent assertion.
        #expect(
            PresentationSnapshot.lines(of: screen, on: analysis) == [
                "family = error",
                "identity.session = session.synthetic",
                "identity.attempt = 1",
                "error.category = \(error.rawValue)",
                "error.messageCopy = analysis-error/\(error.rawValue)",
                "error.recoveryCopy = error-recovery/\(error.rawValue)",
                "recovery = selectAnotherImage",
                "byteStatus = platformTransformedCopy",
                "shortEdge = 768",
                "evidenceReport = nil",
                "workProgress = nil",
                "cancellation = nil",
            ]
        )
    }

    @Test(
        "A session that recorded nothing before failing invents nothing",
        arguments: AnalysisError.allCases
    )
    func errorSnapshotWithoutMeasurements(error: AnalysisError) throws {
        let (analysis, screen) = try Self.project(error, preserving: false)

        // Requirement 3.14 preserves what was recorded; neither field is defaulted when the
        // session failed before recording it.
        #expect(
            PresentationSnapshot.lines(of: screen, on: analysis) == [
                "family = error",
                "identity.session = session.synthetic",
                "identity.attempt = 1",
                "error.category = \(error.rawValue)",
                "error.messageCopy = analysis-error/\(error.rawValue)",
                "error.recoveryCopy = error-recovery/\(error.rawValue)",
                "recovery = selectAnotherImage",
                "byteStatus = nil",
                "shortEdge = nil",
                "evidenceReport = nil",
                "workProgress = nil",
                "cancellation = nil",
            ]
        )
    }

    @Test("Every error category offers the one recovery action, and there is only one")
    func recoveryIsTheSameSingleAction() throws {
        // Requirement 11.18 pairs each category with a recovery action, and Requirement 3.15
        // forbids a new session inheriting anything from the failed one - so the only
        // representable recovery is a new selection. The error screen offers it; whether the
        // *accessibility* retry workflow reads it as available is a separate question that
        // task 11.9 pins, and nothing here claims it does.
        #expect(SessionRecovery.allCases == [.selectAnotherImage])

        for error in AnalysisError.allCases {
            let (analysis, screen) = try Self.project(error, preserving: true)
            #expect(screen.recovery == .selectAnotherImage, "\(error)")
            #expect(analysis.recovery == .selectAnotherImage, "\(error)")
            #expect(analysis.isTerminal, "\(error)")
            #expect(analysis.isWorkInFlight == false, "\(error)")
            #expect(analysis.analysisError == error, "\(error)")
        }
    }

    @Test("Every error category is distinct from every label, lane state, and summary surface")
    func errorSurfacesAreDisjointFromEvidenceSurfaces() {
        // Requirement 11.17 as a snapshot over the copy-surface vocabulary: the ten error
        // categories, the three labels, the five enabled states, the unavailable state, and a
        // Combined Summary all address different surfaces, so none can be rendered as another.
        var addresses: [String] = []
        addresses += PixelLabelKey.allCases.map { VerdictCopySurface.pixelLabel($0).description }
        addresses += ProvenanceStateKey.allCases.map {
            VerdictCopySurface.provenanceState($0).description
        }
        addresses.append(VerdictCopySurface.provenanceUnavailable.description)
        addresses += AnalysisErrorKey.allCases.map {
            VerdictCopySurface.analysisError($0).description
        }
        addresses += AnalysisErrorKey.allCases.map {
            VerdictCopySurface.errorRecovery($0).description
        }
        addresses += CopyFixture.summaryKeys.values.map {
            VerdictCopySurface.combinedSummary($0).description
        }

        #expect(addresses.count == 3 + 5 + 1 + 10 + 10 + 3)
        #expect(Set(addresses).count == addresses.count)

        // And the cancelled terminal is not an error category at all: it has no surface in the
        // vocabulary and no error member on its screen.
        let cancelledScreen = CancelledScreen(identity: ViewStateFixture.identity())
        let members = Mirror(reflecting: cancelledScreen).children.compactMap(\.label)
        #expect(members == ["identity", "recovery"])
    }
}

// MARK: - 8.17, 9.16, 14.9, 14.14: the four disclosure destinations

@Suite("Disclosure destinations, one snapshot per screen")
struct DisclosureScreenSnapshotTests {

    /// The coherent pixel-only input task 11.6 already built, reused rather than restated so
    /// the two files cannot describe different releases.
    static func pixelOnlyInput() throws -> DisclosureScreenInput {
        try DisclosureScreenTests.DisclosureFixture.pixelOnlyInput()
    }

    static func provenanceInput() throws -> DisclosureScreenInput {
        try DisclosureScreenTests.DisclosureFixture.provenanceInput()
    }

    @Test("The four destinations project exactly these snapshots")
    func destinationSnapshots() throws {
        let screens = try DisclosureScreens.projecting(try Self.pixelOnlyInput())

        #expect(
            PresentationSnapshot.lines(of: screens, kind: .privacy) == [
                "kind = privacy",
                "statementCopy = privacy-explanation",
                "entryPath = privacy-behavior",
                "destinations = privacy-behavior",
                """
                blockedSurfaces = absent-data-practice-label,cleanup-deadline-duration-unit,\
                local-provenance-availability-statement,privacy-topic-label,\
                project-funding-statement
                """,
            ]
        )

        #expect(
            PresentationSnapshot.lines(of: screens, kind: .modelInformation) == [
                "kind = model-information",
                "statementCopy = model-information",
                "entryPath = model-information",
                """
                destinations = selected-model-identity,\
                independent-non-peer-reviewed-release-status,invalid-inherited-red-team-status
                """,
                """
                blockedSurfaces = active-limitations-reference-label,\
                independent-release-status-statement,inherited-red-team-status-statement,\
                model-identity-field-label
                """,
            ]
        )

        #expect(
            PresentationSnapshot.lines(of: screens, kind: .scopeAndLimitations) == [
                "kind = scope-and-limitations",
                // The screen's own statement is the approved evidence-scope sentence, which is
                // what Requirement 8.10 fixes for exactly this content.
                "statementCopy = evidence-scope",
                // Reached through the model-information path, which is the path task 11.3
                // mapped the measured-limitations destination to.
                "entryPath = model-information",
                "destinations = measured-limitations",
                """
                blockedSurfaces = pixel-evidence-non-establishment-statement,\
                unsupported-scope-item-label
                """,
            ]
        )

        #expect(
            PresentationSnapshot.lines(of: screens, kind: .correctionChannel) == [
                "kind = correction-channel",
                "statementCopy = correction-channel",
                "entryPath = correction-channel",
                "destinations = correction-channel",
                "blockedSurfaces = correction-channel-address",
            ]
        )
    }

    @Test("The four screens answer for the six destinations, and every screen is named")
    func theTableIsExhaustive() throws {
        #expect(DisclosureScreenKind.allCases.count == 4)
        #expect(RequiredDisclosureDestination.allCases.count == 6)
        #expect(ReportDisclosurePath.allCases.count == 3)

        let screens = try DisclosureScreens.projecting(try Self.pixelOnlyInput())
        var answered: [DisclosureScreenKind: Int] = [:]
        for destination in RequiredDisclosureDestination.allCases {
            answered[screens.screen(for: destination), default: 0] += 1
        }
        #expect(Set(answered.keys) == Set(DisclosureScreenKind.allCases))
        #expect(answered[.privacy] == 1)
        #expect(answered[.modelInformation] == 3)
        #expect(answered[.scopeAndLimitations] == 1)
        #expect(answered[.correctionChannel] == 1)
    }

    @Test("The privacy screen projects exactly this value in a pixel-only release")
    func privacySnapshotPixelOnly() throws {
        let screens = try DisclosureScreens.projecting(try Self.pixelOnlyInput())

        #expect(
            PresentationSnapshot.lines(of: screens.privacy) == [
                "explanationCopy = privacy-explanation",
                "pixelInference = on-device",
                // Requirement 9.16's conditional clause, answered from the signed manifest:
                // this composition links no validator, which is not "found nothing".
                "provenanceValidation = not-part-of-this-release",
                "photoAccess = selected-item-only",
                "networkRequirement = none-for-analysis",
                "modelDelivery = packaged-inside-application",
                "removalScope = every-application-controlled-namespace",
                """
                topics = local-pixel-inference,conditional-local-provenance-validation,\
                selected-item-permission,ephemeral-retention,absence-of-telemetry,\
                bundled-model-behavior,cleanup-deadlines,deletion-behavior
                """,
                """
                absentDataPractices = analytics-collection,custom-diagnostic-transmission,\
                third-party-crash-reporting,analytics-identifier,advertising-identifier
                """,
                // The five deadlines are the synthetic policy's own values, carried through
                // unchanged (Requirement 9.7). No number here is a product value.
                """
                cleanupDeadlines = completed=1000,cancelled=2000,error-terminated=3000,\
                interrupted=4000,abandoned=5000
                """,
                """
                accessClaims = nonprofit-project,zero-monetary-cost,no-account-required,\
                no-advertising,outside-a-subscription
                """,
                "lifecyclePolicy = policy.lifecycle.synthetic",
            ]
        )
    }

    @Test("The capability set changes exactly one line of the privacy snapshot")
    func privacySnapshotDiffersOnlyInTheConditionalStatement() throws {
        let pixelOnly = PresentationSnapshot.lines(
            of: try DisclosureScreens.projecting(try Self.pixelOnlyInput()).privacy
        )
        let provenance = PresentationSnapshot.lines(
            of: try DisclosureScreens.projecting(try Self.provenanceInput()).privacy
        )

        #expect(pixelOnly.count == provenance.count)
        let differing = zip(pixelOnly, provenance).filter { $0.0 != $0.1 }.map(\.1)
        #expect(differing == ["provenanceValidation = validated-on-device"])
    }

    @Test("The model-information screen projects exactly this value")
    func modelInformationSnapshot() throws {
        let input = try Self.pixelOnlyInput()
        let screen = try DisclosureScreens.projecting(input).modelInformation

        #expect(
            [
                "informationCopy = \(PresentationSnapshot.address(screen.informationCopy))",
                "checkpoint = \(screen.modelIdentity.checkpointIdentifier.rawValue)",
                "modelBundle = \(screen.modelBundleID.rawValue)",
                "coreMLModel = \(screen.coreMLModelVersion.rawValue)",
                "calibrationPolicy = \(screen.calibrationPolicyID.rawValue)",
                "peerReview = \(screen.peerReview.rawValue)",
                "redTeamValidation = \(screen.redTeamValidation.rawValue)",
                "presentsAValidReport = \(screen.presentsAValidInheritedRedTeamReport)",
                "activeLimitations = \(screen.activeLimitations.artifact.rawValue)",
            ] == [
                "informationCopy = model-information",
                "checkpoint = checkpoint.synthetic",
                "modelBundle = bundle.synthetic",
                "coreMLModel = component.coreml.synthetic",
                "calibrationPolicy = policy.calibration.synthetic",
                // Requirement 14.9's two disclosures, both read from the governance record.
                "peerReview = independent-non-peer-reviewed",
                "redTeamValidation = no-valid-inherited-report",
                "presentsAValidReport = false",
                "activeLimitations = evidence.active-limitations-publication",
            ]
        )
        // The screen describes the model the session ran under, never a newer one.
        #expect(screen.modelIdentity == input.session.modelIdentity)
        #expect(screen.makesTheRequiredGovernanceDisclosures)
    }

    @Test("The scope-and-limitations screen projects exactly this value")
    func scopeAndLimitationsSnapshot() throws {
        let screen = try DisclosureScreens.projecting(try Self.pixelOnlyInput())
            .scopeAndLimitations

        let covered = screen.coveredScopes.map(\.rawValue).joined(separator: ",")
        let uncovered = screen.uncoveredScopes.map(\.rawValue).joined(separator: ",")
        let unestablished = screen.unestablishedProperties.map(\.rawValue).joined(separator: ",")
        let unframed = screen.propertiesWithoutApprovedFraming
            .map(\.rawValue)
            .joined(separator: ",")
        let explanations = screen.labelExplanations
            .map { "\($0.label.rawValue)=\(PresentationSnapshot.address($0.explanationCopy))" }
            .joined(separator: ",")

        #expect(
            [
                "scopeCopy = \(PresentationSnapshot.address(screen.scopeCopy))",
                "falseResultCopy = \(PresentationSnapshot.address(screen.falseResultCopy))",
                "covered = \(covered)",
                "uncovered = \(uncovered)",
                "evidenceStrength = \(screen.evidenceStrength.rawValue)",
                "unestablished = \(unestablished)",
                "unframed = \(unframed)",
                "explanations = \(explanations)",
            ] == [
                "scopeCopy = evidence-scope",
                "falseResultCopy = false-result-limitation",
                "covered = wholeImageSynthesis",
                """
                uncovered = localizedEdit,composite,vaeReconstruction,video,audio,animatedMedia,\
                additionalStaticFormat,additionalIngestRoute,multipleImages
                """,
                "evidenceStrength = probabilistic-evidence",
                """
                unestablished = authenticity,authorship,intent,editing-sequence,\
                absence-of-localized-editing
                """,
                // Requirement 1.15 is only partly sayable: authorship, intent, and the editing
                // sequence have no approved framing anywhere in the closed vocabulary, and none
                // may be written here.
                "unframed = authorship,intent,editing-sequence",
                """
                explanations = signals-consistent-with-ai-generation=\
                pixel-explanation/signals-consistent-with-ai-generation,\
                no-strong-signal-detected=pixel-explanation/no-strong-signal-detected,\
                not-enough-signal=pixel-explanation/not-enough-signal
                """,
            ]
        )
    }

    @Test("The correction-channel screen carries a reference and claims no address")
    func correctionChannelSnapshot() throws {
        let screen = try DisclosureScreens.projecting(try Self.pixelOnlyInput()).correctionChannel

        #expect(
            [
                "channelCopy = \(PresentationSnapshot.address(screen.channelCopy))",
                "channel = \(screen.channel.artifact.rawValue)",
                "actionableAddress = \(screen.presentsAnActionableAddress)",
            ] == [
                "channelCopy = correction-channel",
                "channel = evidence.correction-channel",
                // Nothing in this repository supplies the channel's contents, so the screen
                // says so rather than showing a placeholder a user might act on.
                "actionableAddress = false",
            ]
        )
    }

    @Test("The four screens partition the twelve recorded gaps with no overlap")
    func recordedGapsPartitionTheVocabulary() {
        // Task 11.6 asserts that the union of the four screens' gaps is the whole vocabulary.
        // What is added here is that the four sets are pairwise disjoint, so a gap is claimed
        // by exactly one screen and an audit reading the four lists sees each one once.
        var counts: [DisclosureScreenKind: Int] = [:]
        var union: Set<UnapprovedDisclosureSurface> = []
        var total = 0
        for kind in DisclosureScreenKind.allCases {
            let recorded = DisclosureScreenSurfaces.recorded(for: kind)
            counts[kind] = recorded.count
            union.formUnion(recorded)
            total += recorded.count
        }

        #expect(UnapprovedDisclosureSurface.allCases.count == 12)
        #expect(counts[.privacy] == 5)
        #expect(counts[.modelInformation] == 4)
        #expect(counts[.scopeAndLimitations] == 2)
        #expect(counts[.correctionChannel] == 1)
        #expect(total == 12)
        #expect(union.count == total)
        #expect(union == Set(UnapprovedDisclosureSurface.allCases))
        #expect(DisclosureScreens.unapprovedSurfaces == union)
    }

    @Test("The same input projects the same four snapshots")
    func disclosureSnapshotsAreDeterministic() throws {
        let input = try Self.pixelOnlyInput()
        let first = try DisclosureScreens.projecting(input)
        let second = try DisclosureScreens.projecting(input)

        for kind in DisclosureScreenKind.allCases {
            #expect(
                PresentationSnapshot.lines(of: first, kind: kind)
                    == PresentationSnapshot.lines(of: second, kind: kind),
                "\(kind)"
            )
        }
        #expect(PresentationSnapshot.lines(of: first.privacy)
            == PresentationSnapshot.lines(of: second.privacy))
    }
}

// MARK: - 8.1, 8.2, 8.18: exact copy, and the recorded absence of the rest

@Suite("Exact copy: three fixed strings, and every other surface recorded as blocked")
struct ExactCopySnapshotTests {

    /// The three display strings Requirement 8.2 fixes, transcribed as literals.
    ///
    /// In ``PixelLabelKey`` declaration order, so they can be compared against a projection
    /// that iterates the vocabulary.
    static let fixedStrings = [
        "Signals consistent with AI generation",
        "No strong signal detected",
        "Not enough signal",
    ]

    @Test("The three fixed strings reach the evidence card unchanged")
    func fixedStringsReachTheCard() throws {
        // Requirement 8.2 governs the *displayed* label, so the assertion is made where a view
        // reads it rather than only on the type that owns it.
        let rendered = try PixelLabelKey.allCases.map { label in
            try ReportFixture.pixelOnlyPresentation(pixel: label.pixelEvidence)
                .cards.pixel.fixedLabelText.value
        }
        #expect(rendered == Self.fixedStrings)
    }

    @Test("The three fixed strings reach the limitations screen unchanged")
    func fixedStringsReachTheDisclosureScreen() throws {
        // The scope-and-limitations screen explains all three labels as a set, so it renders
        // all three strings in one place (Requirements 8.3 through 8.5 and 8.17).
        let screen = try DisclosureScreens.projecting(
            try DisclosureScreenTests.DisclosureFixture.pixelOnlyInput()
        ).scopeAndLimitations

        #expect(screen.labelExplanations.map(\.labelText.value) == Self.fixedStrings)
        #expect(screen.labelExplanations.map(\.label) == PixelLabelKey.allCases)
    }

    @Test("The shipped catalog carries the three fixed pixel-label keys and the chrome keys")
    func theShippedCatalogCarriesTheFixedLabelsAndChrome() throws {
        // The honest statement about "exact copy" in this repository, updated. Two disjoint groups
        // are present and nothing else:
        //
        //   * the three fixed pixel-label keys, whose values Requirement 8.2 fixes character for
        //     character; and
        //   * the six `ChromeCopySurface` keys, which describe what the application is doing rather
        //     than what a model concluded. Their wording is *proposed, not approved* — every entry
        //     says so in its `comment` — and it is here because a control with no name cannot be
        //     used at all, which is a worse failure than wording awaiting sign-off.
        //
        // A key in neither group appearing here would be unapproved verdict wording shipping
        // without a recorded content approval, which is what this test still guards.
        let catalog = try EnglishStringCatalog.loadShippedCatalog()
        let keys = catalog.keys.sorted()

        let fixedLabelKeys = [
            "copy.pixel-label.no-strong-signal-detected",
            "copy.pixel-label.not-enough-signal",
            "copy.pixel-label.signals-consistent-with-ai-generation",
        ]
        let chromeKeys = ChromeCopySurface.requiredLocalizationKeys.map(\.rawValue)

        #expect(keys == (fixedLabelKeys + chromeKeys).sorted())
        #expect(keys.count == 3 + ChromeCopySurface.allCases.count)
        #expect(Set(fixedLabelKeys).isDisjoint(with: Set(chromeKeys)))
        #expect(
            Set(fixedLabelKeys)
                == Set(EnglishStringCatalog.fixedPixelLabelKeys.values.map(\.rawValue))
        )
        // No chrome key addresses a verdict surface, and no verdict surface addresses a chrome key.
        #expect(ChromeCopyCoverage.missingValues(in: catalog).isEmpty)

        let values = PixelLabelKey.allCases.map { label -> String in
            let key = EnglishStringCatalog.fixedPixelLabelKeys[label]!
            return catalog.singleValue(
                forKey: key.rawValue,
                language: EnglishStringCatalog.requiredLanguageTag
            ) ?? "<missing>"
        }
        #expect(values == Self.fixedStrings)
    }

    @Test("Every other addressed surface is a recorded finding, never a rendered string")
    func everyOtherSurfaceIsARecordedFinding() throws {
        // Requirement 8.1 needs an approved *value* for every reachable surface, and this
        // release has three. The rest are named by
        // `StringCatalogError.missingApprovedValues`, which is what makes the absence a
        // release-validation failure rather than a blank screen.
        let catalog = try EnglishStringCatalog.loadShippedCatalog()
        let binding = try ViewStateFixture.pixelOnlyBinding()

        let addressed = binding.reachableSurfaces.surfaces
            .compactMap { binding.localizationKey(for: $0) }
        let fixed = Set(EnglishStringCatalog.fixedPixelLabelKeys.values)
        let expectedMissing = Set(addressed).subtracting(fixed).sorted { $0.rawValue < $1.rawValue }
        let missing = StringCatalogCoverage.missingValues(in: catalog, for: binding)

        // 37 unconditional surfaces: the 8 standalone ones, 3 labels, 3 explanations, 10 error
        // messages, 10 error recoveries, and 3 byte-status limitations.
        #expect(addressed.count == 37)
        #expect(Set(addressed).count == 37)
        #expect(missing == expectedMissing)
        #expect(missing.count == 34)
        let coversAFixedLabel = missing.contains { fixed.contains($0) }
        #expect(coversAFixedLabel == false)
        #expect(throws: StringCatalogError.missingApprovedValues(missing)) {
            try StringCatalogCoverage.audit(catalog, for: binding)
        }
    }

    @Test("A provenance-and-fusion release addresses eight more surfaces, all unapproved")
    func enablingCapabilitiesAddsOnlyUnapprovedSurfaces() throws {
        let catalog = try EnglishStringCatalog.loadShippedCatalog()
        let pixelOnly = try ViewStateFixture.pixelOnlyBinding()
        let fusion = try ViewStateFixture.fusionBinding()

        // Five enabled provenance states and three summary keys, on top of the 37.
        #expect(pixelOnly.reachableSurfaces.surfaces.count == 37)
        #expect(fusion.reachableSurfaces.surfaces.count == 45)
        #expect(
            StringCatalogCoverage.missingValues(in: catalog, for: fusion).count == 42
        )
    }

    @Test("The four recorded gap vocabularies are closed, sized, and pairwise disjoint")
    func gapVocabulariesAreClosedAndSized() {
        // Task 11.6 asserts the six pairwise disjointness relations. What is pinned here is the
        // *size* of each list, so a vocabulary growing without this file noticing is a failure
        // rather than silently reduced coverage.
        #expect(UnapprovedViewStateSurface.allCases.count == 6)
        #expect(UnapprovedReportSurface.allCases.count == 10)
        #expect(UnapprovedAccessibilitySurface.allCases.count == 6)
        #expect(UnapprovedDisclosureSurface.allCases.count == 12)

        let all =
            UnapprovedViewStateSurface.allCases.map(\.rawValue)
            + UnapprovedReportSurface.allCases.map(\.rawValue)
            + UnapprovedAccessibilitySurface.allCases.map(\.rawValue)
            + UnapprovedDisclosureSurface.allCases.map(\.rawValue)
        #expect(all.count == 34)
        #expect(Set(all).count == 34)

        // Every entry names what it gates, so an audit can route each gap to a requirement.
        for surface in UnapprovedReportSurface.allCases {
            #expect(surface.gates.isEmpty == false, "\(surface)")
        }
        for surface in UnapprovedDisclosureSurface.allCases {
            #expect(surface.gates.isEmpty == false, "\(surface)")
        }
    }

    @Test("A projected report stores no sentence at all, in any field, on any shape")
    func noProjectionStoresASentence() throws {
        // The claim first written here was that a report carries exactly one display string,
        // the pixel label. That over-claims, and the measured truth is stronger: a report
        // carries *no* display string. ``FixedPixelLabelText`` stores a ``PixelLabelKey`` and
        // derives ``FixedPixelLabelText/value`` from it, so the three fixed strings are not
        // stored anywhere in the value graph - they are computed from the closed vocabulary at
        // the point a view reads them.
        //
        // So every `String` leaf in a projected report is an identifier or a localization key,
        // and none of them is whitespace-separated prose. That is the executable form of "no
        // presentation model has a field a free-form claim could be written into": there is no
        // sentence-shaped leaf to overwrite.
        var shapes = 0
        for (name, presentation) in try ForbiddenControlSnapshotTests.reportPresentations() {
            let strings = PresentationStringLeaves.collect(in: presentation)
            #expect(strings.isEmpty == false, "\(name)")

            let displayStrings = strings.filter { Self.fixedStrings.contains($0) }
            #expect(displayStrings.isEmpty, "\(name)")

            let sentenceShaped = strings.filter { value in
                value.contains { $0.isWhitespace }
            }
            #expect(sentenceShaped.isEmpty, "\(name)")
            shapes += 1
        }
        #expect(shapes == 29)

        // The three fixed strings are reachable only through the closed label vocabulary, and
        // none of them is a localization key, so a rendered key can never be mistaken for one.
        for label in PixelLabelKey.allCases {
            let text = FixedPixelLabelText(label: label).value
            #expect(Self.fixedStrings.contains(text), "\(label)")
            #expect(text.hasPrefix("copy.") == false, "\(label)")
        }
    }
}

/// Collects the `String` leaves of a presentation value.
///
/// Used to answer "which display strings does this value actually carry", which is the only
/// way to check that the three fixed labels are the whole of the rendered text.
enum PresentationStringLeaves {
    static func collect(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        if let text = value as? String { return [text] }
        return Mirror(reflecting: value).children.flatMap {
            collect(in: $0.value, depth: depth + 1)
        }
    }
}

// MARK: - 8.13, 8.15, 9.15: the forbidden controls, over every enumerated snapshot

@Suite("No enumerated snapshot carries a forbidden control or a prohibited claim")
struct ForbiddenControlSnapshotTests {

    /// Every completed-report presentation this file enumerates.
    static func reportPresentations() throws -> [(String, EvidenceReportPresentation)] {
        var presentations: [(String, EvidenceReportPresentation)] = []
        for evidence in PixelEvidence.allCases {
            for lane in ReportFixture.allLanes {
                let name = "\(evidence.rawValue)/\(lane.category?.rawValue ?? "unavailable")"
                presentations.append(
                    (name, try ReportFixture.provenancePresentation(pixel: evidence, lane: lane))
                )
            }
            presentations.append(
                ("fused/\(evidence.rawValue)", try ReportFixture.fusedPresentation(pixel: evidence))
            )
        }
        for status in BytePreservationStatus.allCases {
            presentations.append(
                (
                    "byte/\(status.rawValue)",
                    try ReportFixture.pixelOnlyPresentation(bytePreservationStatus: status)
                )
            )
        }
        for flag in [false, true] {
            presentations.append(
                (
                    "inconsistent/\(flag)",
                    try ReportFixture.provenancePresentation(
                        lane: ReportFixture.availableLane(.validated),
                        inconsistent: flag
                    )
                )
            )
        }
        return presentations
    }

    @Test("Every completed report passes both audits")
    func everyReportPassesBothAudits() throws {
        let presentations = try Self.reportPresentations()
        var audited = 0

        for (name, presentation) in presentations {
            let prohibited = ProhibitedClaimAudit.findings(in: presentation)
            let forbidden = ForbiddenControlAudit.findings(in: presentation)
            #expect(prohibited.isEmpty, "\(name)")
            #expect(forbidden.isEmpty, "\(name)")
            audited += 1
        }

        // 21 label-by-lane combinations, 3 fused, 3 byte statuses, and 2 contradiction shapes.
        #expect(audited == 29)
        #expect(presentations.count == 29)
    }

    @Test("Every error screen passes both audits")
    func everyErrorScreenPassesBothAudits() throws {
        var audited = 0
        for error in AnalysisError.allCases {
            for preserving in [false, true] {
                let (_, screen) = try AnalysisErrorSnapshotTests.project(
                    error,
                    preserving: preserving
                )
                #expect(ProhibitedClaimAudit.findings(in: screen).isEmpty, "\(error)")
                #expect(ForbiddenControlAudit.findings(in: screen).isEmpty, "\(error)")
                audited += 1
            }
        }
        #expect(audited == 20)
    }

    @Test("Every disclosure destination passes both audits")
    func everyDisclosureScreenPassesBothAudits() throws {
        var audited = 0
        for input in try [
            DisclosureScreenTests.DisclosureFixture.pixelOnlyInput(),
            DisclosureScreenTests.DisclosureFixture.provenanceInput(),
        ] {
            let screens = try DisclosureScreens.projecting(input)
            #expect(ProhibitedClaimAudit.findings(in: screens).isEmpty)
            #expect(ForbiddenControlAudit.findings(in: screens).isEmpty)
            #expect(ProhibitedClaimAudit.findings(in: screens.privacy).isEmpty)
            #expect(ForbiddenControlAudit.findings(in: screens.privacy).isEmpty)
            #expect(ProhibitedClaimAudit.findings(in: screens.modelInformation).isEmpty)
            #expect(ForbiddenControlAudit.findings(in: screens.modelInformation).isEmpty)
            #expect(ProhibitedClaimAudit.findings(in: screens.scopeAndLimitations).isEmpty)
            #expect(ForbiddenControlAudit.findings(in: screens.scopeAndLimitations).isEmpty)
            #expect(ProhibitedClaimAudit.findings(in: screens.correctionChannel).isEmpty)
            #expect(ForbiddenControlAudit.findings(in: screens.correctionChannel).isEmpty)
            audited += 5
        }
        #expect(audited == 10)
    }

    @Test("The excluded-control vocabulary is closed and declared on every report")
    func theExcludedVocabularyIsClosed() throws {
        // Requirements 9.15, 8.13, and 8.15. The enforcement is that no member exists for any
        // of these; the declaration is what lets a release audit enumerate the ban.
        #expect(ExcludedResultControl.allCases.count == 7)
        #expect(EvidenceReportPresentation.excludedControls == Set(ExcludedResultControl.allCases))
        #expect(
            ExcludedResultControl.allCases.map(\.rawValue) == [
                "analysis-history",
                "save-result",
                "export-result",
                "copy-result",
                "share-result",
                "probability-or-confidence-representation",
                "uncalibrated-raw-output-disclosure",
            ]
        )
        for control in ExcludedResultControl.allCases {
            #expect(control.forbiddenBy.isEmpty == false, "\(control)")
        }
    }

    @Test("The audits still detect a violation, so an empty finding list means something")
    func theAuditsAreNotVacuous() {
        // A sweep of empty results is worthless if the audits cannot fail. Two synthetic
        // models, each carrying exactly one thing the audits exist to catch.
        struct WithMagnitude: ProbabilityFreePresentationModel {
            let aiProbability: Double
        }
        struct WithHistory: ProbabilityFreePresentationModel {
            let analysisHistory: [String]
        }

        let magnitude = ProhibitedClaimAudit.findings(in: WithMagnitude(aiProbability: 0.5))
        #expect(magnitude.isEmpty == false)
        #expect(magnitude.count >= 2)

        let history = ForbiddenControlAudit.findings(in: WithHistory(analysisHistory: []))
        #expect(history.isEmpty == false)
        #expect(history.first?.control == .analysisHistory)
    }
}
