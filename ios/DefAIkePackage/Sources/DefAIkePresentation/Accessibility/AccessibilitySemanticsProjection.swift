import DefAIkeDomain

// Projecting one screen into its accessibility semantics.
//
// Pure and total over ``AccessibilityScreenInput``: every screen yields exactly one snapshot,
// there is no failure case, and nothing is read outside the argument. A snapshot is therefore
// reproducible from a value, which is what lets the accessibility tests assert labels, values,
// traits, order, activation areas, and the exact blocked set without a device.
//
// The reading order is written out per family, in the order the fields appear on screen, and
// the array order is the only thing that expresses it (Requirement 12.4). Nothing here sorts,
// nothing compares text, and nothing consults a layout, so the order is the same at every
// Dynamic Type size and under every catalog.
//
// The ordering rule for a completed report follows the report's own structure, because the
// report structure is what the requirements constrain: the two independent lanes first and in
// their declared order, so neither is ranked (Requirements 7.2, 7.3, and 7.8); the Combined
// Summary and the apparent-inconsistency notice after both lanes rather than in place of either
// (Requirements 7.13 and 7.17); the limitations next, because every report states them
// (Requirements 8.10 through 8.12); then the onward paths (Requirement 8.17); then the recovery
// action (Requirement 3.13).
//
// Which elements are exposed and which are blocked is not a judgement call made here. An
// element is exposed when its text is either approved copy the session already resolved or one
// of the three display strings Requirement 8.2 fixes. It is blocked when neither exists. That
// rule is applied field by field below, and the resulting blocked set is the honest statement of
// what Requirement 12 still owes the approved-copy decision.
//
// There are now two approved vocabularies an element's text can be addressed into, and which
// one a surface belongs to is a design decision rather than a convenience:
//
//   * ``VerdictCopySurface``, for copy that describes an evidence outcome. Session-bound,
//     because Requirement 8.1 binds a verdict's wording to the Model Bundle that produced it.
//     Resolving one needs the session's `ApprovedCopyBinding`.
//   * ``ChromeCopySurface``, for copy that describes what the application is doing. Not
//     session-bound, because a control label and a status sentence name no outcome and change
//     no meaning when the bundle changes. The ready and importing screens hold no session and
//     therefore no binding, so this is the only vocabulary they could ever resolve through.
//
// What that leaves blocked is exactly what neither vocabulary defines: the technical-details
// disclosure control, every row inside it, the byte-status and recorded-dimension fields on a
// failed session, and the *values* that would name a field's state in words. Those are recorded
// by task 11.2, 11.3, or ``UnapprovedAccessibilitySurface`` and nothing here invents wording for
// one.
//
// ``UnapprovedViewStateSurface`` is still accurate and still enumerated: Approved Verdict Copy
// genuinely defines none of the six surfaces it names. What changed is that the chrome
// vocabulary now supplies them, so the projection no longer cites those cases as the reason an
// element cannot be built.

extension AccessibilitySemanticsSnapshot {

    /// Projects one screen into its accessibility semantics.
    ///
    /// Total, pure, and independent of the displayed English: every label and value is an
    /// address into approved content, so the same screen projects to the same snapshot under
    /// the shipping catalog and under every Localization Readiness Suite catalog
    /// (Requirement 12.16).
    public static func projecting(_ input: AccessibilityScreenInput) -> Self {
        switch input {
        case .ready: ready(input)
        case let .importing(importing): self.importing(importing, input: input)
        case let .active(active): self.active(active, input: input)
        case let .completed(report): completed(report, input: input)
        case let .cancelled(cancelled): self.cancelled(cancelled, input: input)
        case let .error(failed): error(failed, input: input)
        }
    }

    /// Projects one screen and its session's approved copy, assembling a completed report.
    ///
    /// A convenience over ``AccessibilityScreenInput/init(screen:copy:)``, for a caller holding
    /// a projected screen rather than an assembled report. It refuses exactly what report
    /// assembly refuses and adds no failure of its own.
    public static func projecting(
        screen: AnalysisScreen,
        copy: ApprovedCopyBinding
    ) throws(EvidenceReportAssemblyError) -> Self {
        projecting(try AccessibilityScreenInput(screen: screen, copy: copy))
    }

    // MARK: - Ready

    /// The ready screen: one control, labelled from the chrome vocabulary.
    ///
    /// The label is an address into ``ChromeCopySurface/imageSelectionAction`` rather than a
    /// sentence chosen here, and it is chrome rather than verdict copy because the control
    /// names an application action and not an evidence outcome. That distinction is what makes
    /// this screen renderable at all: a ready screen holds no session and therefore no
    /// `ApprovedCopyBinding`, so a verdict address could not be resolved for it even if
    /// `VerdictCopySurface` had a case for one.
    ///
    /// Nothing is blocked. `ReadyScreen` has no stored property, so there is no state to name
    /// and no second element to expose.
    private static func ready(_ input: AccessibilityScreenInput) -> Self {
        Self(
            family: .ready,
            elements: [
                AccessibleElement(
                    identity: .imageSelectionControl,
                    role: .activatingControl,
                    label: .approvedChromeCopy(ChromeCopyReference(.imageSelectionAction))
                )
            ],
            blockedElements: [],
            announcement: StatusAnnouncement(input)
        )
    }

    // MARK: - Importing

    /// The importing screen: one status field, labelled from the chrome vocabulary.
    ///
    /// The route is still deliberately not turned into a spoken value, and the approved wording
    /// carries none. A route name is a developer identifier, and announcing "photos-picker"
    /// would be rendering an internal key as user-facing text, which is what the approved-copy
    /// mechanism exists to prevent. The status therefore has a label and no value: there is one
    /// thing to say, and the field's own words are it.
    private static func importing(
        _ screen: ImportingScreen,
        input: AccessibilityScreenInput
    ) -> Self {
        Self(
            family: .importing,
            elements: [
                AccessibleElement(
                    identity: .importStatus,
                    role: .statusField,
                    label: .approvedChromeCopy(ChromeCopyReference(.importInProgressStatus))
                )
            ],
            blockedElements: [],
            announcement: StatusAnnouncement(input)
        )
    }

    // MARK: - Active

    /// The active screen: the progress field and the cancel control, both exposed.
    ///
    /// This was the most consequential blockage in the layer, and closing it needed a label for
    /// the cancel control, not a relaxation. Requirement 15.5 keeps that control visible and
    /// enabled throughout active work and Requirement 12.9 gives it a 44-point activation area;
    /// ``AccessibilityRole/activatingControl`` already supplied the traits and the area, and
    /// what was missing was the name Requirement 12.1 requires. It now comes from
    /// ``ChromeCopySurface/cancellationAction``.
    ///
    /// The progress field carries a label and no value. Requirement 12.2 asks for a value that
    /// matches the displayed state, and the state a user would want named is the stage — for
    /// which no approved wording exists, so it stays recorded as an unmet semantic on the
    /// exposed element rather than making the whole field unrenderable. That is the difference
    /// the two lists are for: the field is exposed and imperfect, not absent.
    ///
    /// Nothing here derives a fraction, a percentage, or a remaining time from the stage. The
    /// approved status wording asserts that work is continuing and says nothing measured
    /// (Requirements 15.2, 15.3, and 15.10).
    private static func active(
        _ screen: ActiveScreen,
        input: AccessibilityScreenInput
    ) -> Self {
        Self(
            family: .active,
            elements: [
                AccessibleElement(
                    identity: .workProgress,
                    role: .progressField,
                    label: .approvedChromeCopy(ChromeCopyReference(.analysisInProgressStatus)),
                    unmetSemantics: [.stateValue(.accessibility(.analysisStageValue))]
                ),
                AccessibleElement(
                    identity: .cancellationControl,
                    role: .activatingControl,
                    label: .approvedChromeCopy(ChromeCopyReference(.cancellationAction))
                ),
            ],
            blockedElements: [],
            announcement: StatusAnnouncement(input)
        )
    }

    // MARK: - Cancelled

    /// The cancelled screen: a status field and a recovery control, both exposed.
    ///
    /// Cancellation carries no Analysis Error, and nothing here borrows one. It still does not
    /// borrow approved *error* copy either: the status is addressed to
    /// ``ChromeCopySurface/cancelledStatus``, whose wording states the absence of a result
    /// without naming a failure, because presenting a cancellation as a failure is what
    /// Requirement 11.17 forbids. That is a property of the chrome vocabulary rather than of
    /// this function — there is no error surface in it to reach for.
    private static func cancelled(
        _ screen: CancelledScreen,
        input: AccessibilityScreenInput
    ) -> Self {
        Self(
            family: .cancelled,
            elements: [
                AccessibleElement(
                    identity: .cancelledStatus,
                    role: .statusField,
                    label: .approvedChromeCopy(ChromeCopyReference(.cancelledStatus))
                ),
                AccessibleElement(
                    identity: .imageSelectionControl,
                    role: .activatingControl,
                    label: .approvedChromeCopy(ChromeCopyReference(.imageSelectionAction))
                ),
            ],
            blockedElements: [],
            announcement: StatusAnnouncement(input)
        )
    }

    // MARK: - Error

    /// The error screen: the message and the recovery action, both fully exposed.
    ///
    /// The one screen family whose whole surface is accessible today, because both surfaces it
    /// needs are in the approved vocabulary: the category's message and the recovery that
    /// category offers. The recovery is an operable control whose label is its approved copy, so
    /// it carries the button trait and the 44-point activation area and is reachable by
    /// VoiceOver and Switch Control alike.
    ///
    /// The measurements a failed session preserved are recorded as blocked when they were
    /// recorded at all, and omitted entirely when they were not (Requirement 3.14). Neither is
    /// defaulted, so an absence stays an absence.
    private static func error(
        _ screen: AnalysisErrorScreen,
        input: AccessibilityScreenInput
    ) -> Self {
        var blocked: [BlockedAccessibleElement] = []
        if screen.bytePreservationStatus != nil {
            blocked.append(
                BlockedAccessibleElement(
                    identity: .bytePreservationLimitation,
                    role: .evidenceField,
                    blocking: [
                        .report(.bytePreservationStatusLabel),
                        .accessibility(.bytePreservationStatusValue),
                    ]
                )
            )
        }
        if let quality = screen.inputQuality {
            let dimensions = RecordedDimensions(record: quality)
            blocked += dimensions.recorded.map { recorded in
                BlockedAccessibleElement(
                    identity: .recordedDimension(recorded.dimension),
                    role: .evidenceField,
                    blocking: [
                        .report(.recordedDimensionDefinition),
                        .accessibility(.recordedDimensionValueUnit),
                    ]
                )
            }
        }

        return Self(
            family: .error,
            elements: [
                AccessibleElement(
                    identity: .analysisErrorMessage,
                    role: .evidenceField,
                    label: .approvedCopy(screen.presentation.messageCopy)
                ),
                AccessibleElement(
                    identity: .analysisErrorRecovery,
                    role: .activatingControl,
                    label: .approvedCopy(screen.presentation.recoveryCopy)
                ),
            ],
            blockedElements: blocked,
            announcement: StatusAnnouncement(input)
        )
    }

    // MARK: - Completed

    /// The completed report: both lanes, the summary, the limitations, the paths, the recovery.
    ///
    /// Assembled in displayed order from the report's own already-resolved members, so the
    /// accessibility hierarchy and the visual hierarchy are one list rather than two that can
    /// drift (Requirement 12.4).
    private static func completed(
        _ report: EvidenceReportPresentation,
        input: AccessibilityScreenInput
    ) -> Self {
        var elements: [AccessibleElement] = []
        var blocked: [BlockedAccessibleElement] = []

        // The pixel source lane. Its label is one of the three fixed display strings, so this
        // is the one evidence field that needs no catalog lookup at all. What it lacks is a
        // heading naming the field's purpose, which is recorded rather than invented, so the
        // label falls back to the content the field displays.
        elements.append(
            AccessibleElement(
                identity: .pixelEvidenceLabel,
                role: .evidenceField,
                label: .requiredPixelLabelText(report.cards.pixel.fixedLabelText),
                unmetSemantics: [.purposeLabel(.report(.pixelCardHeading))]
            )
        )
        elements.append(
            AccessibleElement(
                identity: .pixelEvidenceExplanation,
                role: .evidenceField,
                label: .approvedCopy(report.cards.pixel.lane.explanationCopy)
            )
        )

        // The provenance source lane, in its own element, after the pixel lane and never
        // inside it. The distinction between an inconclusive enabled validator and a release
        // that cannot validate at all is already two different approved state strings; what is
        // missing is a spoken value stating the distinction as such (Requirement 6.21).
        elements.append(
            AccessibleElement(
                identity: .provenanceLaneState,
                role: .evidenceField,
                label: .approvedCopy(report.cards.provenance.lane.stateCopy),
                unmetSemantics: [
                    .purposeLabel(.report(.provenanceCardHeading)),
                    .stateValue(.accessibility(.provenanceLaneDistinctionValue)),
                ]
            )
        )
        if case let .shownForAbsentCredential(reference) =
            report.cards.provenance.screenshotExplanation
        {
            elements.append(
                AccessibleElement(
                    identity: .screenshotProvenanceExplanation,
                    role: .evidenceField,
                    label: .approvedCopy(reference)
                )
            )
        }

        // The Combined Summary sits after both lanes, so it reads as an addition rather than a
        // replacement for either. The rule version it names has no approved label, which is
        // recorded here rather than spoken as a bare identifier.
        if let summary = report.combinedSummary.summary {
            elements.append(
                AccessibleElement(
                    identity: .combinedSummary,
                    role: .evidenceField,
                    label: .approvedCopy(summary.summaryCopy),
                    unmetSemantics: [
                        .purposeLabel(.report(.combinedSummaryHeading)),
                        .stateValue(.report(.fusionRuleVersionLabel)),
                    ]
                )
            )
        }
        if let notice = report.apparentInconsistency.reference {
            elements.append(
                AccessibleElement(
                    identity: .apparentInconsistencyNotice,
                    role: .evidenceField,
                    label: .approvedCopy(notice)
                )
            )
        }

        // Every report states these three, so they are appended unconditionally and there is no
        // branch that could drop one.
        elements.append(
            AccessibleElement(
                identity: .evidenceScopeLimitation,
                role: .evidenceField,
                label: .approvedCopy(report.limitations.scopeCopy)
            )
        )
        elements.append(
            AccessibleElement(
                identity: .falseResultLimitation,
                role: .evidenceField,
                label: .approvedCopy(report.limitations.falseResultCopy)
            )
        )
        elements.append(
            AccessibleElement(
                identity: .bytePreservationLimitation,
                role: .evidenceField,
                label: .approvedCopy(report.limitations.bytePreservation.limitationCopy),
                unmetSemantics: [
                    .stateValue(.accessibility(.bytePreservationStatusValue))
                ]
            )
        )

        blocked += technicalDetailBlockages(report.technicalDetails)

        // The three onward paths, each an operable control whose label is its approved copy.
        for path in ReportDisclosurePath.allCases {
            elements.append(
                AccessibleElement(
                    identity: identity(for: path),
                    role: .navigatingControl,
                    label: .approvedCopy(report.disclosurePaths.reference(for: path))
                )
            )
        }

        // The recovery action every terminal screen offers, last in the reading order so it
        // follows the report rather than interrupting it (Requirement 3.13). Chrome copy, not
        // verdict copy: it names an application action, and a completed report's own approved
        // copy has no surface for one.
        elements.append(
            AccessibleElement(
                identity: .imageSelectionControl,
                role: .activatingControl,
                label: .approvedChromeCopy(ChromeCopyReference(.imageSelectionAction))
            )
        )

        return Self(
            family: .completed,
            elements: elements,
            blockedElements: blocked,
            announcement: StatusAnnouncement(input)
        )
    }

    /// The identity of one onward path's control. Total switch, no `default`.
    private static func identity(for path: ReportDisclosurePath) -> AccessibleElementIdentity {
        switch path {
        case .modelInformation: .modelInformationPath
        case .privacyBehavior: .privacyPath
        case .correctionChannel: .correctionChannelPath
        }
    }

    /// Every technical-details element, all of them blocked.
    ///
    /// The values exist and are exposed by the report: six bound component identifiers, the
    /// recorded dimensions, the on-device status, and the verified integrity status. What none
    /// of them has is a field label, which Requirement 8.14 requires alongside them and task
    /// 11.3 recorded as missing, or a spoken value naming the state in words.
    ///
    /// Enumerated per row rather than as one lump, so a release audit sees how many labels the
    /// approved-copy decision owes rather than a single line saying "technical details".
    /// Unrecorded dimensions are omitted entirely: a dimension the session never measured is
    /// not a field whose label is missing.
    private static func technicalDetailBlockages(
        _ details: EvidenceTechnicalDetails
    ) -> [BlockedAccessibleElement] {
        var blocked: [BlockedAccessibleElement] = [
            BlockedAccessibleElement(
                identity: .technicalDetailsDisclosure,
                role: .disclosureControl,
                blocking: [.report(.technicalDetailsSectionLabel)]
            )
        ]
        blocked += DisclosedComponent.allCases.map { component in
            BlockedAccessibleElement(
                identity: .boundComponentVersion(component),
                role: .evidenceField,
                blocking: [.report(.boundComponentVersionDefinition)]
            )
        }
        blocked += details.dimensions.recorded.map { recorded in
            BlockedAccessibleElement(
                identity: .recordedDimension(recorded.dimension),
                role: .evidenceField,
                blocking: [
                    .report(.recordedDimensionDefinition),
                    .accessibility(.recordedDimensionValueUnit),
                ]
            )
        }
        blocked.append(
            BlockedAccessibleElement(
                identity: .onDeviceProcessingStatus,
                role: .evidenceField,
                blocking: [
                    .report(.onDeviceProcessingStatusLabel),
                    .accessibility(.onDeviceProcessingStatusValue),
                ]
            )
        )
        blocked.append(
            BlockedAccessibleElement(
                identity: .modelBundleIntegrityStatus,
                role: .evidenceField,
                blocking: [
                    .report(.modelBundleIntegrityStatusLabel),
                    .accessibility(.modelBundleIntegrityStatusValue),
                ]
            )
        )
        return blocked
    }
}

// MARK: - Focus preservation

extension AccessibilitySemanticsSnapshot {
    /// What becomes of accessibility focus when this snapshot replaces `previous`
    /// (Requirement 12.6).
    ///
    /// Decided by identity, not by position: an element that moved down the reading order
    /// because a new field appeared above it is still the same element, so focus stays on it.
    /// Focus moves only when the focused element is genuinely absent from the new screen, and
    /// then to the first element of the new reading order rather than nowhere.
    ///
    /// A screen with nothing exposed suggests no target. That is the honest answer for the
    /// families whose whole surface is blocked, and it is one more reason the blockage is
    /// recorded rather than hidden.
    public func focusRetention(
        movingFrom previous: AccessibleElementIdentity?
    ) -> FocusRetention {
        guard let previous else { return .noFocusedElement }
        if exposes(previous) { return .retained(previous) }
        return .movedBecauseElementIsGone(
            vanished: previous,
            suggestedTarget: elements.first?.identity
        )
    }
}
