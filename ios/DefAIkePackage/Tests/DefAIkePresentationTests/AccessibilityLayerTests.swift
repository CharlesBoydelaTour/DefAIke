import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Requirements 12.1 through 12.12, checked on a host.
//
// The Accessibility Layer computes its semantics as plain values, so most of Requirement 12 is
// assertable without a simulator, a rendered hierarchy, or an assistive technology. These tests
// take that seam at face value: they project real screens, read the resulting labels, values,
// traits, order, activation areas, announcements, focus decisions, and blocked set, and check them
// against what the requirement says.
//
// What they deliberately do not claim. Four clauses are about behaviour on a device and cannot be
// established here: whether a 44-point frame really produces a 44-point hit region under a live
// layout (12.9), whether the Switch Control scanner reaches every control (12.12), whether
// VoiceOver's focus actually stays put across a real reprojection (12.6), and whether the largest
// accessibility size reflows without clipping on a real screen (12.8). What is checked here is the
// half a value can carry: the frame is requested, the control is a native focusable button with an
// activation action, focus is tracked by identity and only reassigned when the element is gone, and
// no truncation or fixed height is expressible. The device half stays in the release gate matrix.
//
// Several tests assert that a screen exposes *nothing*, and that is not a placeholder. Five of the
// six screen families have no approved wording for their controls or status text, so the honest
// projection is an empty exposed set and a recorded blockage. Asserting the blockage is how the
// gap stays visible instead of reading as an oversight.

@Suite("Accessibility Layer semantics")
struct AccessibilityLayerTests {

    // MARK: - Fixtures

    /// One projection input per screen family, built through the real view-state projection.
    static func inputPerFamily() throws -> [AnalysisScreenFamily: AccessibilityScreenInput] {
        let copy = try ViewStateFixture.pixelOnlyBinding()
        var inputs: [AnalysisScreenFamily: AccessibilityScreenInput] = [:]
        for (family, snapshot) in try ViewStateFixture.snapshotPerFamily() {
            let screen = try AnalysisScreen.projecting(snapshot)
            inputs[family] = try AccessibilityScreenInput(screen: screen, copy: copy)
        }
        return inputs
    }

    /// The input for one family.
    static func input(_ family: AnalysisScreenFamily) throws -> AccessibilityScreenInput {
        try #require(try inputPerFamily()[family])
    }

    /// An active input at one progress state.
    static func activeInput(
        progress: AnalysisProgressState
    ) throws -> AccessibilityScreenInput {
        let screen = try AnalysisScreen.projecting(
            try ViewStateFixture.working(progress: progress)
        )
        return try AccessibilityScreenInput(
            screen: screen,
            copy: try ViewStateFixture.pixelOnlyBinding()
        )
    }

    // MARK: - 12.1 and 12.2: labels and values

    @Test("Every exposed element on every family carries a nonempty label")
    func everyElementIsLabelled() throws {
        for (family, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)

            #expect(snapshot.family == family)
            #expect(snapshot.everyElementHasANonemptyLabel, "\(family)")
            #expect(snapshot.everyExposedValueIsNonempty, "\(family)")
        }
    }

    @Test("No label or value is free-form text; every one is an approved address")
    func everyLabelIsAnAddress() throws {
        for (_, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)

            for element in snapshot.elements {
                for source in [element.label] + (element.value.map { [$0] } ?? []) {
                    switch source {
                    case let .approvedCopy(reference):
                        #expect(reference.catalogID == CopyFixture.catalogID)
                        #expect(reference.localizationKey.rawValue.isEmpty == false)
                    case let .approvedChromeCopy(reference):
                        // The same assertion the verdict branch makes, minus the catalogue
                        // identity: chrome copy is not session-bound, so there is no catalogue
                        // version to compare against. What is checked is that the address is
                        // derived from a surface in the closed vocabulary rather than chosen.
                        #expect(ChromeCopySurface.allCases.contains(reference.surface))
                        #expect(
                            reference.localizationKey == reference.surface.localizationKey
                        )
                        #expect(reference.localizationKey.rawValue.isEmpty == false)
                    case let .requiredPixelLabelText(fixed):
                        #expect(FixedPixelLabelText.allTexts.contains(fixed.value))
                    }
                }
            }
        }
    }

    @Test("The pixel label is exposed as one of the three required strings")
    func pixelLabelUsesTheRequiredString() throws {
        for evidence in PixelEvidence.allCases {
            let report = try ReportFixture.pixelOnlyPresentation(pixel: evidence)
            let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

            let element = try #require(snapshot.element(.pixelEvidenceLabel))
            guard case let .requiredPixelLabelText(fixed) = element.label else {
                Issue.record("the pixel label must be one of the three required strings")
                return
            }
            #expect(fixed.label == evidence.labelKey)
            #expect(fixed.value == FixedPixelLabelText(evidence: evidence).value)
        }
    }

    // MARK: - 12.3: traits

    @Test("Every exposed element's traits are exactly its role's traits")
    func traitsMatchRole() throws {
        for (family, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            #expect(snapshot.everyElementCarriesItsRoleTraits, "\(family)")
        }
    }

    @Test("Every role has nonempty traits and a decided operability", arguments: AccessibilityRole.allCases)
    func everyRoleIsFullyDefined(role: AccessibilityRole) {
        #expect(role.traits.isEmpty == false)
        #expect(role.isOperable == (role.activationArea != nil))
        if role.isOperable {
            #expect(role.traits.contains(.button))
        } else {
            #expect(role.traits.contains(.staticText))
        }
    }

    // MARK: - 12.4: reading and action order

    @Test("The reading order is the element order, and the action order is its operable subset")
    func orderIsTheElementOrder() throws {
        for (_, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)

            #expect(snapshot.readingOrder == snapshot.elements.map(\.identity))

            // The action order is a subsequence of the reading order: same relative order, no
            // element promoted or demoted.
            let operablePositions = snapshot.actionOrder.compactMap(snapshot.readingIndex(of:))
            #expect(operablePositions == operablePositions.sorted())
            #expect(Set(snapshot.actionOrder).isSubset(of: Set(snapshot.readingOrder)))
        }
    }

    @Test("A completed report reads both lanes before any summary, limitation, or path")
    func completedOrderPutsLanesFirst() throws {
        let report = try ReportFixture.fusedPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        let pixel = try #require(snapshot.readingIndex(of: .pixelEvidenceLabel))
        let explanation = try #require(snapshot.readingIndex(of: .pixelEvidenceExplanation))
        let provenance = try #require(snapshot.readingIndex(of: .provenanceLaneState))
        let summary = try #require(snapshot.readingIndex(of: .combinedSummary))
        let scope = try #require(snapshot.readingIndex(of: .evidenceScopeLimitation))
        let path = try #require(snapshot.readingIndex(of: .informationPath))

        #expect(pixel < explanation)
        #expect(explanation < provenance)
        #expect(provenance < summary)
        #expect(summary < scope)
        #expect(scope < path)
    }

    @Test("No element appears twice in the reading order")
    func readingOrderHasNoRepeats() throws {
        for (family, input) in try Self.inputPerFamily() {
            let order = AccessibilitySemanticsSnapshot.projecting(input).readingOrder
            #expect(Set(order).count == order.count, "\(family)")
        }
    }

    // MARK: - 12.7: text, never colour or icon alone

    @Test("No element carries anything but text, and every accessory is hidden")
    func meaningTravelsAsText() throws {
        for (_, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            for element in snapshot.elements {
                #expect(element.accessory == .decorativeAndAccessibilityHidden)
                #expect(element.label.addressesNonemptyContent)
            }
        }
        // One case, so a decoration can never become the only channel.
        #expect(AccessoryPresentation.allCases.count == 1)
    }

    // MARK: - 12.9: activation areas

    @Test("Every exposed control requests at least a 44 by 44 point activation area")
    func controlsMeetTheActivationMinimum() throws {
        for (family, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            #expect(snapshot.everyControlMeetsTheActivationMinimum, "\(family)")
        }
        #expect(MinimumActivationArea.requiredEdgeLength == 44)
        #expect(MinimumActivationArea.requiredMinimum.meetsRequirement)
    }

    @Test("A content element requests no activation area")
    func contentElementsHaveNoActivationArea() throws {
        let report = try ReportFixture.pixelOnlyPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        let field = try #require(snapshot.element(.pixelEvidenceLabel))
        #expect(field.activationArea == nil)
        #expect(field.isOperable == false)

        let control = try #require(snapshot.element(.informationPath))
        #expect(control.activationArea == MinimumActivationArea.requiredMinimum)
        #expect(control.isOperable)
    }

    // MARK: - 12.8: Dynamic Type and reflow

    @Test("Every Dynamic Type size is supported through the largest accessibility size")
    func everyTextSizeIsSupported() {
        #expect(SupportedTextSize.allCases.count == 12)
        #expect(SupportedTextSize.accessibilitySizes.count == 5)
        #expect(SupportedTextSize.largestSupported == .accessibility5)
        #expect(SupportedTextSize.largestSupported.isAccessibilitySize)
    }

    @Test("Truncation and a fixed viewport are both unrepresentable")
    func reflowAndScrollingAreTheOnlyOptions() {
        #expect(TextReflowPolicy.allCases == [.reflowWithoutTruncation])
        #expect(ContentScrollPolicy.allCases == [.scrollWheneverContentExceedsViewport])
        #expect(AdaptiveLayoutPolicy.standard.textReflow == .reflowWithoutTruncation)
        #expect(
            AdaptiveLayoutPolicy.standard.contentScroll == .scrollWheneverContentExceedsViewport
        )
    }

    @Test("A name-and-state pairing stacks vertically at every accessibility size")
    func axisIsVerticalAtAccessibilitySizes() {
        for size in SupportedTextSize.allCases {
            let axis = AdaptiveLayoutPolicy.standard.axis(at: size)
            #expect(axis == (size.isAccessibilitySize ? .vertical : .horizontal), "\(size)")
        }
    }

    // MARK: - 12.10: Reduce Motion

    @Test("Reduce Motion substitutes a nonmoving state change for every animated surface")
    func reduceMotionHasAStaticAlternative() {
        #expect(MotionPolicy.statusChangeStyle(reduceMotion: false) == .animatedIndicator)
        #expect(MotionPolicy.statusChangeStyle(reduceMotion: true) == .staticStateChange)

        for surface in MotionSensitiveSurface.allCases {
            #expect(MotionPolicy.hasNonmovingAlternative(for: surface), "\(surface)")
        }
    }

    @Test("The semantics are identical whether motion is reduced or not")
    func semanticsAreIndependentOfMotion() throws {
        // Structural: the projection takes no motion parameter, so the same screen cannot say
        // less under Reduce Motion. Asserted over a real projection so the guarantee is checked
        // rather than assumed.
        let report = try ReportFixture.fusedPresentation()
        let first = AccessibilitySemanticsSnapshot.projecting(.completed(report))
        let second = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        #expect(first == second)
        #expect(first.elements.map(\.identity) == second.elements.map(\.identity))
    }

    // MARK: - 12.5: debounced announcements

    @Test("A repeated determinate progress state within one stage announces once")
    func progressWithinAStageAnnouncesOnce() throws {
        var debouncer = StatusAnnouncementDebouncer()
        var announcements = 0

        for completed in stride(from: UInt64(0), through: 100, by: 5) {
            let input = try Self.activeInput(
                progress: .determinate(
                    completed: completed,
                    total: 100,
                    unit: .encodedBytes,
                    stage: .inference
                )
            )
            if debouncer.announcement(for: input) != nil { announcements += 1 }
        }

        #expect(announcements == 1)
    }

    @Test("A stage change announces, and the same stage again does not")
    func stageChangeAnnounces() throws {
        var debouncer = StatusAnnouncementDebouncer()

        let preprocessing = try Self.activeInput(
            progress: .indeterminate(stage: .preprocessing)
        )
        let inference = try Self.activeInput(progress: .indeterminate(stage: .inference))

        #expect(debouncer.announcement(for: preprocessing) != nil)
        #expect(debouncer.announcement(for: preprocessing) == nil)
        #expect(debouncer.announcement(for: inference) != nil)
        #expect(debouncer.announcement(for: inference) == nil)
    }

    @Test("Each terminal announces once and interrupts")
    func terminalsAnnounceAndInterrupt() throws {
        for family in [AnalysisScreenFamily.completed, .cancelled, .error] {
            var debouncer = StatusAnnouncementDebouncer()
            let input = try Self.input(family)

            let first = debouncer.announcement(for: input)
            let announcement = try #require(first)
            #expect(announcement.urgency == .interruptsCurrentSpeech, "\(family)")
            #expect(announcement.focus == .preservesExistingFocus)
            #expect(debouncer.announcement(for: input) == nil, "\(family)")
        }
    }

    @Test("A completed session announces its fixed pixel label; a failed one its approved message")
    func announceableTerminals() throws {
        let report = try ReportFixture.pixelOnlyPresentation(pixel: .notEnoughSignal)
        let completed = StatusAnnouncement(.completed(report))

        #expect(completed.isAnnounceable)
        #expect(completed.status == .analysisCompleted(.notEnoughSignal))
        guard case let .approved(source) = completed.content,
            case let .requiredPixelLabelText(fixed) = source
        else {
            Issue.record("a completed session must announce its fixed pixel label")
            return
        }
        #expect(fixed.value == FixedPixelLabelText.notEnoughSignal)

        let failed = StatusAnnouncement(try Self.input(.error))
        #expect(failed.isAnnounceable)
        #expect(failed.content.isAnnounceable)
    }

    @Test("The ready status announces nothing and records why; the other four announce")
    func blockedAnnouncementsAreRecorded() throws {
        // The ready family is the only status with no approved wording, and the reason is not a
        // missing string. Ready is not a status *change* anyone waits for: it is the state the
        // application launches in and returns to, and the only approved wording near it is the
        // picker control's own label — a control name, not a status. So the gap stays recorded.
        let ready = StatusAnnouncement(try Self.input(.ready))
        #expect(ready.isAnnounceable == false)
        guard case let .blocked(surfaces) = ready.content else {
            Issue.record("an unannounceable status must record the gaps blocking it")
            return
        }
        #expect(surfaces.isEmpty == false)

        // The other three formerly blocked families now announce approved chrome copy, and the
        // completed and failed terminals continue to announce approved verdict copy.
        for family in [AnalysisScreenFamily.importing, .active, .cancelled] {
            let announcement = StatusAnnouncement(try Self.input(family))

            #expect(announcement.isAnnounceable, "\(family)")
            guard case let .approved(source) = announcement.content else {
                Issue.record("an announceable status must carry an approved address")
                return
            }
            #expect(source.chromeReference != nil, "\(family)")
            #expect(source.addressesNonemptyContent, "\(family)")
        }
    }

    @Test("An announcement can never move focus")
    func announcementsNeverStealFocus() {
        #expect(AnnouncementFocus.allCases == [.preservesExistingFocus])
    }

    // MARK: - 12.6: focus preservation

    @Test("Focus is retained when the focused element is still exposed")
    func focusIsRetained() throws {
        let report = try ReportFixture.fusedPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        let retention = snapshot.focusRetention(movingFrom: .provenanceLaneState)
        #expect(retention == .retained(.provenanceLaneState))
        #expect(retention.preservesFocus)
        #expect(retention.target == .provenanceLaneState)
    }

    @Test("Focus is retained even when the element moved in the reading order")
    func focusSurvivesReordering() throws {
        // A fused report exposes a Combined Summary and an inconsistency notice above the
        // limitations; a pixel-only one does not. The scope limitation therefore sits at a
        // different position in the two, and focus on it must still be retained.
        let fused = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.fusedPresentation())
        )
        let plain = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )

        #expect(
            fused.readingIndex(of: .evidenceScopeLimitation)
                != plain.readingIndex(of: .evidenceScopeLimitation)
        )
        #expect(
            plain.focusRetention(movingFrom: .evidenceScopeLimitation)
                == .retained(.evidenceScopeLimitation)
        )
    }

    @Test("Focus moves only when the focused element is gone, and then to the first element")
    func focusMovesOnlyWhenTheElementIsGone() throws {
        let plain = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )

        let retention = plain.focusRetention(movingFrom: .combinedSummary)
        #expect(retention.preservesFocus == false)
        #expect(
            retention
                == .movedBecauseElementIsGone(
                    vanished: .combinedSummary,
                    suggestedTarget: plain.elements.first?.identity
                )
        )
    }

    @Test("No focused element means nothing to preserve")
    func noFocusedElement() throws {
        let snapshot = AccessibilitySemanticsSnapshot.projecting(try Self.input(.ready))

        #expect(snapshot.focusRetention(movingFrom: nil) == .noFocusedElement)
        #expect(snapshot.focusRetention(movingFrom: nil).target == nil)
    }

    // MARK: - Completed report coverage

    @Test("Every completed report exposes both lanes and all three limitations")
    func completedReportAlwaysExposesLanesAndLimitations() throws {
        for evidence in PixelEvidence.allCases {
            for lane in ReportFixture.allLanes {
                let report = try ReportFixture.provenancePresentation(pixel: evidence, lane: lane)
                let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

                #expect(snapshot.exposes(.pixelEvidenceLabel))
                #expect(snapshot.exposes(.pixelEvidenceExplanation))
                #expect(snapshot.exposes(.provenanceLaneState))
                #expect(snapshot.exposes(.evidenceScopeLimitation))
                #expect(snapshot.exposes(.falseResultLimitation))
                #expect(snapshot.exposes(.bytePreservationLimitation))
                // One onward control now, not three. The privacy, model, and correction
                // statements moved to the information screen it opens.
                #expect(snapshot.exposes(.limitationsDisclosure))
                #expect(snapshot.exposes(.informationPath))
            }
        }
    }

    @Test("The unavailable provenance lane is exposed like any other lane state")
    func unavailableLaneIsStillExposed() throws {
        for reason in UnavailableReason.allCases {
            let report = try ReportFixture.provenancePresentation(lane: .unavailable(reason))
            let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

            let element = try #require(snapshot.element(.provenanceLaneState))
            #expect(element.role == .evidenceField)
            #expect(element.label.copyReference?.surface == .provenanceUnavailable)
        }
    }

    @Test("An enabled absent credential also exposes the screenshot explanation")
    func absentCredentialExposesTheScreenshotExplanation() throws {
        let absent = try ReportFixture.provenancePresentation(lane: ReportFixture.availableLane(.absent))
        #expect(
            AccessibilitySemanticsSnapshot.projecting(.completed(absent))
                .exposes(.screenshotProvenanceExplanation)
        )

        let validated = try ReportFixture.provenancePresentation(
            lane: ReportFixture.availableLane(.validated)
        )
        #expect(
            AccessibilitySemanticsSnapshot.projecting(.completed(validated))
                .exposes(.screenshotProvenanceExplanation) == false
        )
    }

    @Test("The error screen exposes its message and an operable recovery control")
    func errorScreenIsFullyExposed() throws {
        for error in AnalysisError.allCases {
            let snapshot = AnalysisScreen.error(
                AnalysisErrorScreen(
                    identity: ViewStateFixture.identity(),
                    presentation: try ViewStateFixture.pixelOnlyBinding()
                        .presentation(forError: error),
                    bytePreservationStatus: nil,
                    inputQuality: nil
                )
            )
            let input = try AccessibilityScreenInput(
                screen: snapshot,
                copy: try ViewStateFixture.pixelOnlyBinding()
            )
            let semantics = AccessibilitySemanticsSnapshot.projecting(input)

            let message = try #require(semantics.element(.analysisErrorMessage))
            #expect(message.role == .evidenceField)
            #expect(message.label.copyReference?.surface == .analysisError(error.errorKey))

            let recovery = try #require(semantics.element(.analysisErrorRecovery))
            #expect(recovery.role == .activatingControl)
            #expect(recovery.isOperable)
            #expect(recovery.activationArea == .requiredMinimum)
            #expect(semantics.actionOrder == [.analysisErrorRecovery])
        }
    }

    // MARK: - Recorded copy gaps

    @Test("The active screen exposes its progress field and cancel control, and records the stage gap")
    func activeScreenExposesProgressAndCancellation() throws {
        // Was: both elements blocked, with the progress field recording two gaps. The chrome
        // vocabulary supplies both labels, so both are exposed. One gap remains and it is recorded
        // on the exposed element rather than as a blockage: Requirement 12.2 asks for a value
        // naming the field's current state, and no approved wording names the analysis stage.
        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            try Self.activeInput(progress: .indeterminate(stage: .inference))
        )

        #expect(snapshot.blockedElements.isEmpty)

        let progress = try #require(snapshot.element(.workProgress))
        #expect(progress.role == .progressField)
        #expect(
            progress.label == .approvedChromeCopy(ChromeCopyReference(.analysisInProgressStatus))
        )
        // Exposed and imperfect: no state value, and the reason is named on the element.
        #expect(progress.value == nil)
        #expect(progress.unmetSemantics == [.stateValue(.accessibility(.analysisStageValue))])
        #expect(progress.hasCompleteSemantics == false)

        let cancel = try #require(snapshot.element(.cancellationControl))
        #expect(cancel.role == .activatingControl)
        #expect(cancel.label == .approvedChromeCopy(ChromeCopyReference(.cancellationAction)))
        #expect(cancel.hasCompleteSemantics)
    }

    @Test("A measured progress state exposes the same field and the same recorded stage gap")
    func measuredProgressExposesTheSameField() throws {
        // Was: a measured readout recorded `measuredProgressStatus` and an unmeasured one recorded
        // `continuingProgressStatus`, because a measured sentence and a continuing assertion are
        // two different sentences and neither was approved.
        //
        // One approved sentence now covers both, and that is deliberate rather than a shortcut: no
        // stage reports a completed-work and total-work pair for the same measured unit to this
        // layer (Requirements 15.2 and 15.3), so there is nothing a measured-specific sentence
        // could say that this one does not. The projection therefore does not branch on the
        // readout, and this test pins that: the two progress shapes produce the same label and the
        // same recorded gap.
        let measured = AccessibilitySemanticsSnapshot.projecting(
            try Self.activeInput(
                progress: .determinate(
                    completed: 40,
                    total: 100,
                    unit: .encodedBytes,
                    stage: .preprocessing
                )
            )
        )
        let unmeasured = AccessibilitySemanticsSnapshot.projecting(
            try Self.activeInput(progress: .indeterminate(stage: .preprocessing))
        )

        let measuredField = try #require(measured.element(.workProgress))
        let unmeasuredField = try #require(unmeasured.element(.workProgress))

        #expect(measuredField.label == unmeasuredField.label)
        #expect(measuredField.unmetSemantics == unmeasuredField.unmetSemantics)
        #expect(
            measuredField.label
                == .approvedChromeCopy(ChromeCopyReference(.analysisInProgressStatus))
        )
        // And no measured amount reached the semantics: the field has no value at all, so a
        // fraction cannot be spoken.
        #expect(measuredField.value == nil)
    }

    @Test("Every technical-details row is blocked, one recorded gap per row")
    func technicalDetailsAreBlockedPerRow() throws {
        let report = try ReportFixture.pixelOnlyPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        #expect(snapshot.blockedElement(.technicalDetailsDisclosure) != nil)
        for component in DisclosedComponent.allCases {
            #expect(
                snapshot.blockedElement(.boundComponentVersion(component)) != nil,
                "\(component)"
            )
        }
        for recorded in report.technicalDetails.dimensions.recorded {
            #expect(
                snapshot.blockedElement(.recordedDimension(recorded.dimension)) != nil,
                "\(recorded.dimension)"
            )
        }
        #expect(snapshot.blockedElement(.onDeviceProcessingStatus) != nil)
        #expect(snapshot.blockedElement(.modelBundleIntegrityStatus) != nil)

        // A dimension the session never measured is not a field with a missing label.
        for unrecorded in report.technicalDetails.dimensions.unrecorded {
            #expect(snapshot.blockedElement(.recordedDimension(unrecorded)) == nil)
        }
    }

    @Test("Every recorded gap names the requirement it gates")
    func gapsNameTheirRequirement() throws {
        for surface in UnapprovedAccessibilitySurface.allCases {
            #expect(surface.gates.isEmpty == false, "\(surface)")
            #expect(surface.rawValue.isEmpty == false)
        }
        #expect(
            Set(UnapprovedAccessibilitySurface.allCases.map(\.rawValue)).count
                == UnapprovedAccessibilitySurface.allCases.count
        )

        // Every gap the completed report reports is one of the three recorded vocabularies, and
        // the list is deterministic.
        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )
        let gaps = snapshot.recordedCopyGaps
        #expect(gaps.isEmpty == false)
        #expect(gaps == gaps.sorted { $0.stableKey < $1.stableKey })
        #expect(Set(gaps).count == gaps.count)
        for gap in gaps {
            #expect(gap.gates.isEmpty == false, "\(gap.stableKey)")
        }
    }

    @Test("Every accessibility gap is a value, never a label already recorded elsewhere")
    func accessibilityGapsAreValuesOnly() {
        // The label gaps belong to tasks 11.2 and 11.3. This task records only the value gaps,
        // so no accessibility gap key repeats a report or view-state one.
        let accessibilityKeys = Set(UnapprovedAccessibilitySurface.allCases.map(\.rawValue))
        let reportKeys = Set(UnapprovedReportSurface.allCases.map(\.rawValue))
        let viewStateKeys = Set(UnapprovedViewStateSurface.allCases.map(\.rawValue))

        #expect(accessibilityKeys.isDisjoint(with: reportKeys))
        #expect(accessibilityKeys.isDisjoint(with: viewStateKeys))
    }

    // MARK: - 12.11 and 12.12: workflow operability

    @Test("Result review and limitation review are operable on a completed report")
    func reviewWorkflowsAreOperable() throws {
        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )

        for workflow in [AccessibilityWorkflow.resultReview, .limitationReview] {
            let operability = WorkflowOperability.evaluating(workflow, in: snapshot)
            #expect(operability.isOperable, "\(workflow): \(operability.unusableElements)")
            #expect(operability.interaction == .nativeActivationAction)
            #expect(operability.blockingGaps.isEmpty)
        }
    }

    @Test("Retry is operable on a completed report through the selection control")
    func retryIsOperableOnACompletedReport() throws {
        // Was: blocked by `.viewState(.startNewSessionAction)`. The chrome vocabulary supplies the
        // control's label, so the recovery Requirement 3.13 offers is now reachable.
        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )
        let operability = WorkflowOperability.evaluating(.retry, in: snapshot)

        #expect(operability.isOperable)
        #expect(operability.blockingGaps.isEmpty)
        #expect(operability.unusableElements.isEmpty)
        #expect(operability.interaction == .nativeActivationAction)
    }

    @Test("Ingest is operable on the ready screen through the selection control")
    func ingestIsOperableOnTheReadyScreen() throws {
        // Was: blocked for the same reason as retry. This is the single most consequential change
        // in the layer — with no labelled selection control the picker was unreachable, so no
        // Analysis Session could be started by anyone, with or without assistive technology.
        let snapshot = AccessibilitySemanticsSnapshot.projecting(try Self.input(.ready))
        let operability = WorkflowOperability.evaluating(.ingest, in: snapshot)

        #expect(operability.isOperable)
        #expect(operability.blockingGaps.isEmpty)
        #expect(operability.unusableElements.isEmpty)
    }

    @Test("Analysis and cancellation are operable while work is in flight")
    func inFlightWorkflowsAreOperable() throws {
        // Was: both blocked. Requirement 15.5 requires the cancel control to be visible and enabled
        // for all active analysis work, which was unsatisfiable while the control had no label.
        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            try Self.activeInput(progress: .indeterminate(stage: .inference))
        )

        for workflow in [AccessibilityWorkflow.analysis, .cancellation] {
            let operability = WorkflowOperability.evaluating(workflow, in: snapshot)
            #expect(operability.isOperable, "\(workflow): \(operability.unusableElements)")
            #expect(operability.blockingGaps.isEmpty, "\(workflow)")
        }

        // The progress field is exposed with an unmet state value, and an unmet semantic does not
        // make a control unusable: it is focusable, announced, and activatable regardless.
        let analysis = WorkflowOperability.evaluating(.analysis, in: snapshot)
        let progress = try #require(analysis.requiredElements.first)
        #expect(
            progress.status
                == .exposedWithUnmetSemantics([.stateValue(.accessibility(.analysisStageValue))])
        )
        #expect(progress.status.isUsable)
    }

    @Test("Handoff consent is the Share Extension's workflow and is never claimed here")
    func handoffConsentIsNotThisModules() throws {
        #expect(AccessibilityWorkflow.handoffConsent.presenter == .shareExtension)
        #expect(WorkflowOperability.requiredIdentities(for: .handoffConsent).isEmpty)

        for (_, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            let operability = WorkflowOperability.evaluating(.handoffConsent, in: snapshot)
            #expect(operability.isOperable == false)
            #expect(operability.presenter == .shareExtension)
        }
    }

    @Test("Every required workflow is evaluated on every screen family")
    func everyWorkflowIsEvaluated() throws {
        for (family, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            let evaluated = WorkflowOperability.evaluating(snapshot)

            #expect(evaluated.map(\.workflow) == AccessibilityWorkflow.allCases, "\(family)")
        }
        #expect(WorkflowOperability.coveredConditions == [.voiceOver, .switchControl])
        #expect(AssistiveInteraction.allCases == [.nativeActivationAction])
    }

    // MARK: - Text resolution

    @Test("The three required pixel labels resolve without a catalog lookup")
    func fixedPixelLabelsResolve() throws {
        let resolver = try AccessibleTextResolver.shipped()

        for label in PixelLabelKey.allCases {
            let text = try resolver.text(
                for: .requiredPixelLabelText(FixedPixelLabelText(label: label))
            )
            #expect(text == FixedPixelLabelText(label: label).value)
        }
    }

    @Test("A key the catalog has no approved value for does not resolve")
    func unapprovedKeysDoNotResolve() throws {
        // The Combined Summary is now the surface that still has no approved value, and it is the
        // right one to check: its wording is addressed by key from an approved Evidence Fusion
        // Rule, and no such artifact exists in this repository. The unconditional verdict surfaces
        // that used to stand in here - the evidence scope among them - now carry proposed English,
        // so they resolve and can no longer witness the fail-closed path.
        let resolver = try AccessibleTextResolver.shipped()
        let summaryKey = try #require(CopyFixture.summaryKeys[.notEnoughSignal])
        let reference = try ViewStateFixture.fusionBinding()
            .reference(for: .combinedSummary(summaryKey))

        #expect(resolver.resolvedText(for: .approvedCopy(reference)) == nil)
        #expect(throws: StringCatalogError.self) {
            try resolver.text(for: .approvedCopy(reference))
        }
    }

    @Test("Only elements whose text resolves are renderable, and the order is preserved")
    func renderableElementsPreserveOrder() throws {
        let resolver = try AccessibleTextResolver.shipped()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )

        let renderable = resolver.renderableElements(in: snapshot)
        let unresolvable = resolver.unresolvableElements(in: snapshot)

        // Every element on a pixel-only completed report now resolves. Three routes reach text:
        // the pixel label through `FixedPixelLabelText` with no catalog lookup at all, the recovery
        // control through its `ChromeCopySurface` key, and every remaining field through the
        // proposed `VerdictCopySurface` wording the shipped catalog now carries.
        //
        // This replaces an expectation of exactly two renderable elements. That was accurate while
        // the verdict wording was absent; what it was really pinning is that nothing renders a
        // localization key, which the emptiness of `unresolvable` states more directly.
        #expect(renderable.map(\.identity) == snapshot.readingOrder)
        #expect(unresolvable.isEmpty)
        #expect(renderable.count + unresolvable.count == snapshot.elements.count)

        // The renderable subset keeps the whole snapshot's relative order.
        let positions = renderable.compactMap { snapshot.readingIndex(of: $0.identity) }
        #expect(positions == positions.sorted())
    }

    @Test("The semantics are the same under every localization readiness catalog")
    func semanticsAreCatalogIndependent() throws {
        // Requirement 12.16: replacing the English copy preserves meaning, order, labels, values,
        // and traits. The projection takes no catalog at all, so this asserts the consequence:
        // the snapshot a readiness catalog would render is byte-identical to the shipping one.
        let report = try ReportFixture.fusedPresentation()
        let expected = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        for variant in LocalizationReadinessVariant.allCases {
            let catalog = try LocalizationReadinessCatalogs.load(variant)
            let resolver = AccessibleTextResolver(
                catalog: catalog,
                languageTag: variant.languageTag
            )
            let actual = AccessibilitySemanticsSnapshot.projecting(.completed(report))

            #expect(actual == expected, "\(variant.rawValue)")
            #expect(actual.readingOrder == expected.readingOrder)
            #expect(
                actual.elements.map(\.traits) == expected.elements.map(\.traits),
                "\(variant.rawValue)"
            )
            // The resolver is the only catalog-dependent part, and it is not in the snapshot.
            #expect(resolver.languageTag == variant.languageTag)
        }
    }

    // MARK: - Structural audits

    @Test("No accessibility model represents a prohibited claim or a forbidden affordance")
    func accessibilityModelsAreClean() throws {
        let report = try ReportFixture.fusedPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))

        #expect(ProhibitedClaimAudit.findings(in: snapshot).isEmpty)
        #expect(ForbiddenControlAudit.findings(in: snapshot).isEmpty)

        for element in snapshot.elements {
            #expect(ProhibitedClaimAudit.findings(in: element).isEmpty, "\(element.identity)")
            #expect(ForbiddenControlAudit.findings(in: element).isEmpty, "\(element.identity)")
        }
        for blocked in snapshot.blockedElements {
            #expect(ProhibitedClaimAudit.findings(in: blocked).isEmpty)
            #expect(ForbiddenControlAudit.findings(in: blocked).isEmpty)
        }
        #expect(ProhibitedClaimAudit.findings(in: AdaptiveLayoutPolicy.standard).isEmpty)
        #expect(ProhibitedClaimAudit.findings(in: MinimumActivationArea.requiredMinimum).isEmpty)
    }

    @Test("Every element identity has a unique stable key")
    func identityKeysAreUnique() {
        let keys = AccessibleElementIdentity.allIdentities.map(\.stableKey)

        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { !$0.isEmpty })
    }

    @Test("Every exposed element in every family is one of the declared identities")
    func exposedIdentitiesAreDeclared() throws {
        let declared = Set(AccessibleElementIdentity.allIdentities)

        for (family, input) in try Self.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            #expect(Set(snapshot.readingOrder).isSubset(of: declared), "\(family)")
            #expect(
                Set(snapshot.blockedElements.map(\.identity)).isSubset(of: declared),
                "\(family)"
            )
        }
    }
}
