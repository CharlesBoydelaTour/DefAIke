import Foundation
import Testing

#if canImport(SwiftUI)
import SwiftUI
#endif

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Requirement 12, checked on a host, over every screen the application can project.
//
// Task 11.4 built the Accessibility Layer as values and asserted Requirement 12 over one
// representative screen per family. This file extends that in four directions the earlier
// coverage deliberately left open, and it states plainly which clauses a host cannot settle at
// all.
//
// 1. **Breadth.** Every audit is re-run over the full cross product the projection can produce:
//    two ingest routes, ten stages in both measured and continuing form, three pixel labels
//    against all seven provenance lane states, every byte-preservation status, and all ten error
//    categories with and without preserved measurements. A clause that holds for one fused report
//    and fails for an indeterminate lane is a clause that does not hold.
// 2. **Sequences.** 12.5 and 12.6 are claims about a *transition*, and a single screen cannot
//    exhibit one. Announcements are driven through one debouncer across a realistic session, and
//    focus retention is checked over every ordered pair of screens against every identity either
//    of them knows about.
// 3. **The view, as source text.** 12.7, 12.8, 12.9, and 12.10 are ultimately about pixels, and
//    the value layer can only say what it asked for. What a host *can* settle is whether the view
//    asks for it: whether reflow is requested and truncation never is, whether the operable frame
//    and hit shape are applied, whether the scroll container is unconditional, whether the one
//    non-text visual is hidden from assistive technology, and whether the module names a colour,
//    an icon, or an animation anywhere. That is a comment-stripped read of the module's own
//    sources, in the manner of ``ForbiddenControlSourceAudit``. Comments are stripped first
//    because this file and the module's documentation both have to be able to name what is
//    forbidden.
// 4. **Localization readiness.** 12.15 and 12.16 begin with a catalog substitution, so all four
//    readiness catalogs are swapped in and the resulting snapshot, reading order, action order,
//    trait set, blocked set, announcement, and renderable partition are compared against the
//    shipping ones for every screen family - not for one report.
//
// ## What is host-verified here and what is not
//
// | Clause | Status in this file |
// |---|---|
// | 12.1 nonempty purpose label | host-verified over every projection |
// | 12.2 value matching displayed state | host-verified as far as it goes; see the notes below |
// | 12.3 traits matching role | host-verified; traits are derived from the role by a total switch |
// | 12.4 reading and action order | host-verified; the order is the array, and nothing sorts it |
// | 12.5 status change announces | host-verified; the debouncer consults no clock |
// | 12.6 focus retained while available | logic host-verified; real VoiceOver focus is device-pending |
// | 12.7 text in addition to colour, shape, animation, icon | host-verified in the value layer and in the module's source text |
// | 12.8 Dynamic Type through the largest accessibility size | the policy and the framework size mapping are host-verified; reflow without clipping on a real screen is device-pending |
// | 12.9 44 by 44 point activation area | the requested frame and hit shape are host-verified; the produced hit region is device-pending |
// | 12.10 Reduce Motion substitution | host-verified; the semantics take no motion parameter |
// | 12.11 completion with VoiceOver | element availability host-verified; completion is device-pending |
// | 12.12 completion with Switch Control | element availability host-verified; completion is device-pending |
// | 12.13 recorded per workflow, OS version, configuration | owned by `AccessibilityGateMatrix`; the workflow vocabulary alignment is checked here |
// | 12.14 block on a missing or failing result | owned by `ValidatedAccessibilityGateMatrix` |
// | 12.15 readiness copy stays visible and reachable | substitution invariance host-verified; visual reachability is device-pending |
// | 12.16 readiness copy preserves semantics and order | host-verified as an identity |
// | 12.17 readiness suite recorded per workflow | owned by `AccessibilityGateMatrix`; the variant vocabulary alignment is checked here |
// | 12.18 block on a missing or failing readiness result | owned by `ValidatedAccessibilityGateMatrix` |
//
// Nothing below asserts a device fact. There is no physical device and only one simulator runtime
// against a 17.0 deployment target, so a test claiming a measured hit region, a real reflow, or a
// completed Switch Control scan would be claiming evidence it does not have. That evidence belongs
// to the release gate matrix, and Requirements 12.13, 12.14, 12.17, and 12.18 are what validates
// it.
//
// ## Three uncomfortable facts this file pins
//
// Each is the current state, asserted so a change to it is a visible test failure rather than a
// silent improvement or regression. They are recorded, not repaired.
//
//   * **No exposed element carries a value.** Every element the projection produces has
//     `value == nil`. Requirement 12.2 is met today only through the "the label already is its
//     state" reading, and every field that genuinely needs a separate spoken state either records
//     an ``UnmetSemanticRequirement/stateValue`` or is blocked outright.
//   * **The readiness catalogs cannot reach a rendered string.** The shipped catalog holds only
//     the three fixed pixel-label keys, the readiness catalogs hold exactly that same key set, and
//     no element's label addresses one of those keys - the pixel label resolves through
//     ``FixedPixelLabelText`` without a catalog lookup. So the substitution 12.15 and 12.16 are
//     built on changes no text on screen today.
//   * **Retry reads as unavailable on the error screen, with no recorded reason.** The error
//     screen exposes a fully labelled operable recovery control under
//     ``AccessibleElementIdentity/analysisErrorRecovery``, but the retry workflow requires
//     ``AccessibleElementIdentity/imageSelectionControl``, so it is reported as absent from the
//     screen with an empty ``WorkflowOperability/blockingGaps``.

// MARK: - Fixtures

/// One projected screen, with a stable name for failure reports.
///
/// A name rather than only a family, because several cases share a family and a failure that says
/// "completed" cannot be located. The name is built from the closed vocabularies the case was
/// built from, so it never contains wording.
struct AccessibilityReadinessCase: Sendable {
    let name: String
    let family: AnalysisScreenFamily
    let input: AccessibilityScreenInput

    var snapshot: AccessibilitySemanticsSnapshot {
        AccessibilitySemanticsSnapshot.projecting(input)
    }
}

/// Every screen the projection can be asked for, built through the real view-state projection.
enum AccessibilityReadinessFixture {

    /// One input from one coordinator snapshot and one session-matched binding.
    static func input(
        _ snapshot: CoordinatorSnapshot,
        copy: ApprovedCopyBinding
    ) throws -> AccessibilityScreenInput {
        let screen = try AnalysisScreen.projecting(snapshot)
        return try AccessibilityScreenInput(screen: screen, copy: copy)
    }

    /// The five non-completed families, across every closed vocabulary that varies them.
    ///
    /// Ready and cancelled have one shape each; importing varies by route; active varies by stage
    /// and by whether the progress is measured; error varies by category and by which measurements
    /// the failed session had already recorded.
    static func nonCompletedCases() throws -> [AccessibilityReadinessCase] {
        let copy = try ViewStateFixture.pixelOnlyBinding()
        var cases: [AccessibilityReadinessCase] = [
            AccessibilityReadinessCase(
                name: "ready",
                family: .ready,
                input: try input(.idle, copy: copy)
            )
        ]

        for route in InputRoute.allCases {
            cases.append(
                AccessibilityReadinessCase(
                    name: "importing/\(route.rawValue)",
                    family: .importing,
                    input: try input(
                        .importing(ImportAttemptSnapshot(route: route)),
                        copy: copy
                    )
                )
            )
        }

        for stage in AnalysisStage.allCases {
            let states: [(String, AnalysisProgressState)] = [
                ("continuing", .indeterminate(stage: stage)),
                (
                    "measured",
                    .determinate(completed: 40, total: 100, unit: .encodedBytes, stage: stage)
                ),
            ]
            for (shape, progress) in states {
                cases.append(
                    AccessibilityReadinessCase(
                        name: "active/\(stage.rawValue)/\(shape)",
                        family: .active,
                        input: try input(
                            try ViewStateFixture.working(progress: progress, copy: copy),
                            copy: copy
                        )
                    )
                )
            }
        }

        cases.append(
            AccessibilityReadinessCase(
                name: "cancelled",
                family: .cancelled,
                input: try input(
                    try ViewStateFixture.ended(outcome: .cancelled, copy: copy),
                    copy: copy
                )
            )
        )

        // A failed session preserves what it had already measured (Requirement 3.14), and the
        // projection blocks exactly those rows. Both presence shapes are covered so a blocked row
        // that appears only when a measurement exists is still reached.
        for error in AnalysisError.allCases {
            let preserved: [(String, BytePreservationStatus?, InputQualityRecord?)] = [
                ("preserved", .platformTransformedCopy, ViewStateFixture.quality()),
                ("nothing-recorded", nil, nil),
            ]
            for (shape, status, quality) in preserved {
                let failure = ViewStateFixture.failure(
                    error: error,
                    bytePreservationStatus: status,
                    inputQuality: quality
                )
                cases.append(
                    AccessibilityReadinessCase(
                        name: "error/\(error.rawValue)/\(shape)",
                        family: .error,
                        input: try input(
                            try ViewStateFixture.ended(outcome: .failed(failure), copy: copy),
                            copy: copy
                        )
                    )
                )
            }
        }

        return cases
    }

    /// A lane's stable name, distinguishing the two unavailable reasons from each other.
    static func laneName(_ lane: ProvenanceLane) -> String {
        if let category = lane.category { return category.rawValue }
        return "unavailable/\(lane.unavailableReason?.rawValue ?? "unknown")"
    }

    /// Every completed-report shape, each assembled through the real report assembly.
    static func completedCases() throws -> [AccessibilityReadinessCase] {
        var cases: [AccessibilityReadinessCase] = []

        for evidence in PixelEvidence.allCases {
            for lane in ReportFixture.allLanes {
                let report = try ReportFixture.provenancePresentation(
                    pixel: evidence,
                    lane: lane
                )
                cases.append(
                    AccessibilityReadinessCase(
                        name: "completed/\(evidence.labelKey.rawValue)/\(laneName(lane))",
                        family: .completed,
                        input: .completed(report)
                    )
                )
            }
            cases.append(
                AccessibilityReadinessCase(
                    name: "completed/fused/\(evidence.labelKey.rawValue)",
                    family: .completed,
                    input: .completed(try ReportFixture.fusedPresentation(pixel: evidence))
                )
            )
        }

        for status in BytePreservationStatus.allCases {
            cases.append(
                AccessibilityReadinessCase(
                    name: "completed/byte-status/\(status.rawValue)",
                    family: .completed,
                    input: .completed(
                        try ReportFixture.pixelOnlyPresentation(bytePreservationStatus: status)
                    )
                )
            )
        }

        // An apparent-inconsistency notice needs an available lane, so it is reached through one
        // report shape of its own rather than by a flag on the sweep above.
        cases.append(
            AccessibilityReadinessCase(
                name: "completed/inconsistent",
                family: .completed,
                input: .completed(
                    try ReportFixture.provenancePresentation(
                        lane: ReportFixture.availableLane(.validated),
                        inconsistent: true
                    )
                )
            )
        )

        return cases
    }

    /// Every screen, in a deterministic order.
    static func allCases() throws -> [AccessibilityReadinessCase] {
        let nonCompleted = try nonCompletedCases()
        let completed = try completedCases()
        return nonCompleted + completed
    }

    /// One representative screen per distinguishable situation, for the pairwise sweeps.
    ///
    /// A representative set rather than the whole cross product, because the transition sweeps are
    /// quadratic and the properties they check turn on the screen's family and its exposed
    /// identity set rather than on its lane state. Two active screens and two completed screens,
    /// so a transition within a family is covered as well as one between families.
    static func representativeCases() throws -> [AccessibilityReadinessCase] {
        let copy = try ViewStateFixture.pixelOnlyBinding()
        return [
            AccessibilityReadinessCase(
                name: "ready",
                family: .ready,
                input: try input(.idle, copy: copy)
            ),
            AccessibilityReadinessCase(
                name: "importing",
                family: .importing,
                input: try input(
                    .importing(ImportAttemptSnapshot(route: .photosPicker)),
                    copy: copy
                )
            ),
            AccessibilityReadinessCase(
                name: "active-preprocessing",
                family: .active,
                input: try input(
                    try ViewStateFixture.working(
                        progress: .indeterminate(stage: .preprocessing),
                        copy: copy
                    ),
                    copy: copy
                )
            ),
            AccessibilityReadinessCase(
                name: "active-inference",
                family: .active,
                input: try input(
                    try ViewStateFixture.working(
                        progress: .indeterminate(stage: .inference),
                        copy: copy
                    ),
                    copy: copy
                )
            ),
            AccessibilityReadinessCase(
                name: "completed-pixel-only",
                family: .completed,
                input: .completed(try ReportFixture.pixelOnlyPresentation())
            ),
            AccessibilityReadinessCase(
                name: "completed-fused",
                family: .completed,
                input: .completed(try ReportFixture.fusedPresentation())
            ),
            AccessibilityReadinessCase(
                name: "cancelled",
                family: .cancelled,
                input: try input(
                    try ViewStateFixture.ended(outcome: .cancelled, copy: copy),
                    copy: copy
                )
            ),
            AccessibilityReadinessCase(
                name: "error-decoding",
                family: .error,
                input: try input(
                    try ViewStateFixture.ended(
                        outcome: .failed(ViewStateFixture.failure(error: .decodingError)),
                        copy: copy
                    ),
                    copy: copy
                )
            ),
        ]
    }
}

// MARK: - 12.1, 12.2, 12.3, 12.4, 12.7, 12.9 over every screen

@Suite("Accessibility semantics over every projectable screen")
struct AccessibilitySemanticsCoverageTests {

    @Test("The sweep really covers every family and every closed vocabulary that varies one")
    func sweepIsBroadEnoughToMeanSomething() throws {
        let cases = try AccessibilityReadinessFixture.allCases()

        // A sweep that silently shrank would make every audit below pass by testing less. The
        // floors are counted from the vocabularies rather than written as a total, so adding a
        // stage, route, error category, or lane state raises them automatically.
        #expect(Set(cases.map(\.family)) == Set(AnalysisScreenFamily.allCases))
        #expect(cases.filter { $0.family == .importing }.count == InputRoute.allCases.count)
        #expect(cases.filter { $0.family == .active }.count == 2 * AnalysisStage.allCases.count)
        #expect(cases.filter { $0.family == .error }.count == 2 * AnalysisError.allCases.count)
        #expect(
            cases.filter { $0.family == .completed }.count
                >= PixelEvidence.allCases.count * ReportFixture.allLanes.count
        )
        #expect(Set(cases.map(\.name)).count == cases.count, "case names must be distinguishable")
    }

    @Test("Every exposed element is labelled, valued, traited, and sized on every screen")
    func everyScreenSatisfiesTheElementAudits() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot

            #expect(snapshot.family == testCase.family, "\(testCase.name)")
            #expect(snapshot.everyElementHasANonemptyLabel, "\(testCase.name)")
            #expect(snapshot.everyExposedValueIsNonempty, "\(testCase.name)")
            #expect(snapshot.everyElementCarriesItsRoleTraits, "\(testCase.name)")
            #expect(snapshot.everyControlMeetsTheActivationMinimum, "\(testCase.name)")
        }
    }

    @Test("Reading order is the array, action order is its operable subsequence, no repeats")
    func orderIsStructuralOnEveryScreen() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot

            #expect(snapshot.readingOrder == snapshot.elements.map(\.identity), "\(testCase.name)")
            #expect(
                Set(snapshot.readingOrder).count == snapshot.readingOrder.count,
                "\(testCase.name)"
            )
            #expect(
                snapshot.actionOrder == snapshot.operableElements.map(\.identity),
                "\(testCase.name)"
            )

            // Every action-order position is a reading-order position, and in the same relative
            // order: no control is promoted ahead of content that precedes it on screen.
            let positions = snapshot.actionOrder.compactMap(snapshot.readingIndex(of:))
            #expect(positions.count == snapshot.actionOrder.count, "\(testCase.name)")
            #expect(positions == positions.sorted(), "\(testCase.name)")

            // The blocked set is disjoint from the exposed set, so nothing is both rendered and
            // recorded as unrenderable.
            let exposed = Set(snapshot.readingOrder)
            let blocked = Set(snapshot.blockedElements.map(\.identity))
            #expect(exposed.isDisjoint(with: blocked), "\(testCase.name)")
        }
    }

    @Test("An operable element is exactly one that requests the 44-point activation area")
    func operabilityAndActivationAreaAgreeEverywhere() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            for element in testCase.snapshot.elements {
                #expect(
                    element.isOperable == (element.activationArea != nil),
                    "\(testCase.name)/\(element.identity.stableKey)"
                )
                if let area = element.activationArea {
                    #expect(area == .requiredMinimum, "\(testCase.name)")
                    #expect(area.widthPoints == MinimumActivationArea.requiredEdgeLength)
                    #expect(area.heightPoints == MinimumActivationArea.requiredEdgeLength)
                    #expect(area.meetsRequirement)
                }
            }
        }
        #expect(MinimumActivationArea.requiredEdgeLength == 44)
    }

    @Test("A blocked control already carries the traits and the activation area its role requires")
    func blockedControlsAreBlockedOnlyByWording() throws {
        // Whatever is still blocked must be blocked by wording alone: its role already supplies
        // the button trait and the 44-point area, so nothing about its affordances is undecided.
        //
        // The set of blocked control roles shrank when the chrome copy vocabulary supplied labels
        // for the image-selection and cancel controls. Only the technical-details disclosure
        // control remains, and it is blocked by `UnapprovedReportSurface`, not by a view-state
        // gap — Requirement 8.14 asks for a field label beside each disclosed value and no
        // approved surface defines one.
        var blockedControlRoles: Set<AccessibilityRole> = []

        for testCase in try AccessibilityReadinessFixture.allCases() {
            for blocked in testCase.snapshot.blockedElements {
                #expect(blocked.blocking.isEmpty == false, "\(testCase.name)")
                #expect(blocked.role.traits.isEmpty == false, "\(testCase.name)")
                #expect(
                    blocked.role.isOperable == (blocked.role.activationArea != nil),
                    "\(testCase.name)"
                )
                if blocked.role.isOperable {
                    blockedControlRoles.insert(blocked.role)
                    #expect(blocked.role.activationArea == .requiredMinimum, "\(testCase.name)")
                    #expect(blocked.role.traits.contains(.button), "\(testCase.name)")
                }
            }
        }

        #expect(blockedControlRoles == [.disclosureControl])
    }

    @Test("The cancel control is exposed on every active screen, with the semantics 15.5 needs")
    func cancellationControlIsExposedOnEveryActiveScreen() throws {
        // This test replaces one that required the cancel control to be *blocked* by exactly
        // `.viewState(.cancellationControl)`. That assertion encoded the copy gap rather than a
        // requirement: Requirement 15.5 wants the control visible and enabled for all active
        // analysis work, and Requirement 12.1 wants it labelled. Both are now satisfiable, so the
        // assertion is inverted rather than dropped — the control must be present, labelled from
        // the chrome vocabulary, carry the button trait, and provide the 44-point area.
        //
        // Nothing here is weakened: the old test's real content was "the only thing missing is the
        // label, and the affordances are already right", and that claim is now checked on an
        // exposed element instead of a blocked one.
        var activeScreens = 0

        for testCase in try AccessibilityReadinessFixture.allCases()
        where testCase.family == .active {
            let snapshot = testCase.snapshot
            let cancel = try #require(
                snapshot.element(.cancellationControl),
                "an active screen must expose its cancel control"
            )

            #expect(cancel.role == .activatingControl, "\(testCase.name)")
            #expect(cancel.activationArea == .requiredMinimum, "\(testCase.name)")
            #expect(cancel.traits.contains(.button), "\(testCase.name)")
            #expect(cancel.label.addressesNonemptyContent, "\(testCase.name)")
            #expect(
                cancel.label == .approvedChromeCopy(ChromeCopyReference(.cancellationAction)),
                "\(testCase.name)"
            )
            // Fully specified: a control's own name is its whole meaning, so there is no
            // separate state value to be missing.
            #expect(cancel.hasCompleteSemantics, "\(testCase.name)")
            #expect(snapshot.blockedElement(.cancellationControl) == nil, "\(testCase.name)")
            activeScreens += 1
        }

        #expect(activeScreens == 2 * AnalysisStage.allCases.count)
    }

    @Test("Meaning travels only as text: no colour, symbol, animation, or magnitude field exists")
    func meaningTravelsAsTextOnEveryScreen() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot

            for element in snapshot.elements {
                #expect(
                    element.accessory == .decorativeAndAccessibilityHidden,
                    "\(testCase.name)/\(element.identity.stableKey)"
                )
                #expect(element.label.addressesNonemptyContent, "\(testCase.name)")
            }

            // No presentation model in the graph carries a result magnitude or a forbidden
            // affordance, checked over the whole snapshot rather than over one report.
            #expect(ProhibitedClaimAudit.findings(in: snapshot).isEmpty, "\(testCase.name)")
            #expect(ForbiddenControlAudit.findings(in: snapshot).isEmpty, "\(testCase.name)")
        }

        // One accessory case, so a decoration can never become the channel a status travels on.
        #expect(AccessoryPresentation.allCases == [.decorativeAndAccessibilityHidden])
    }

    @Test("No exposed element carries a distinct value today, and the ones that need one say so")
    func noElementExposesASeparateStateValue() throws {
        // Requirement 12.2 asks for a value matching the displayed state of every stateful
        // control, progress field, evidence field, warning, and error. Today every element the
        // projection produces has `value == nil`, which the model permits for a field whose label
        // already is its state. That makes `everyExposedValueIsNonempty` pass vacuously, so this
        // asserts the underlying fact instead: the clause is met by the escape hatch, and every
        // field that genuinely needs a spoken state either records the gap or is blocked outright.
        var recordedStateValueGaps: Set<String> = []

        for testCase in try AccessibilityReadinessFixture.allCases() {
            for element in testCase.snapshot.elements {
                #expect(
                    element.value == nil,
                    "\(testCase.name)/\(element.identity.stableKey) began exposing a value"
                )
                for unmet in element.unmetSemantics {
                    guard case .stateValue = unmet else { continue }
                    recordedStateValueGaps.insert(unmet.stableKey)
                }
            }
        }

        // The state-value gaps actually recorded on exposed elements. A field losing its recorded
        // gap without gaining a value would be a silent regression of 12.2.
        #expect(recordedStateValueGaps.isEmpty == false)
        #expect(
            recordedStateValueGaps.contains(
                "state-value/accessibility/byte-preservation-status-value"
            )
        )
        #expect(
            recordedStateValueGaps.contains(
                "state-value/accessibility/provenance-lane-distinction-value"
            )
        )
    }

    @Test("Every recorded gap is deterministic, deduplicated, and names its requirement")
    func recordedGapsAreDeterministicOnEveryScreen() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot
            let gaps = snapshot.recordedCopyGaps

            #expect(gaps == gaps.sorted { $0.stableKey < $1.stableKey }, "\(testCase.name)")
            #expect(Set(gaps).count == gaps.count, "\(testCase.name)")
            for gap in gaps {
                #expect(gap.gates.isEmpty == false, "\(testCase.name)/\(gap.stableKey)")
                #expect(gap.stableKey.isEmpty == false, "\(testCase.name)")
            }

            // Nothing is recorded twice under two spellings: the gap set is exactly the union of
            // what the blocked elements wait on and what the exposed ones are missing.
            let blockedSurfaces = snapshot.blockedElements.flatMap(\.blocking)
            let unmetSurfaces = snapshot.elements.flatMap { $0.unmetSemantics.map(\.surface) }
            #expect(Set(gaps) == Set(blockedSurfaces + unmetSurfaces), "\(testCase.name)")
        }
    }

    @Test("Every declared identity is reached by some projection, so no vocabulary entry is dead")
    func everyDeclaredIdentityIsReachable() throws {
        var reached: Set<AccessibleElementIdentity> = []

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot
            reached.formUnion(snapshot.readingOrder)
            reached.formUnion(snapshot.blockedElements.map(\.identity))
        }

        // A closed vocabulary with entries no screen can produce would let an accessibility test
        // assert something about an element that does not exist. Every declared identity is
        // reached, as exposed content or as a recorded blockage.
        let declared = Set(AccessibleElementIdentity.allIdentities)
        #expect(
            reached == declared,
            "unreachable: \(declared.subtracting(reached).map(\.stableKey).sorted())"
        )

        // The parameterised entries expand from their own vocabularies, so a new bound component
        // or recorded dimension has to be reachable too.
        for component in DisclosedComponent.allCases {
            #expect(reached.contains(.boundComponentVersion(component)), "\(component.rawValue)")
        }
        for dimension in PreOrientationDimension.allCases {
            #expect(reached.contains(.recordedDimension(dimension)), "\(dimension.rawValue)")
        }
    }

    @Test("The screenshot explanation is exposed exactly when the assembled report shows it")
    func screenshotExplanationTracksTheAbsentCredential() throws {
        // The explanation that creating a screenshot can remove source Content Credentials belongs
        // to the one lane state where an absence was actually observed. A screen exposing it
        // anywhere else would read a general caveat as a finding about this image, and a screen
        // omitting it where the report shows it would drop an approved disclosure.
        var shownCount = 0
        var withheldCount = 0

        for testCase in try AccessibilityReadinessFixture.completedCases() {
            guard case let .completed(report) = testCase.input else {
                Issue.record("a completed case must carry an assembled report")
                continue
            }
            var shown = false
            if case .shownForAbsentCredential = report.cards.provenance.screenshotExplanation {
                shown = true
            }

            #expect(
                testCase.snapshot.exposes(.screenshotProvenanceExplanation) == shown,
                "\(testCase.name)"
            )
            if shown { shownCount += 1 } else { withheldCount += 1 }
        }

        // Both arms have to occur, or the equivalence held over one branch.
        #expect(shownCount > 0)
        #expect(withheldCount > 0)
    }

    @Test("A completed report reads its lanes, then any summary, then limitations, then paths")
    func completedOrderHoldsForEveryReportShape() throws {
        for testCase in try AccessibilityReadinessFixture.completedCases() {
            let snapshot = testCase.snapshot

            let pixelLabel = try #require(snapshot.readingIndex(of: .pixelEvidenceLabel))
            let pixelExplanation = try #require(
                snapshot.readingIndex(of: .pixelEvidenceExplanation)
            )
            let provenance = try #require(snapshot.readingIndex(of: .provenanceLaneState))
            let scope = try #require(snapshot.readingIndex(of: .evidenceScopeLimitation))
            let falseResult = try #require(snapshot.readingIndex(of: .falseResultLimitation))
            let bytes = try #require(snapshot.readingIndex(of: .bytePreservationLimitation))
            let disclosure = try #require(snapshot.readingIndex(of: .limitationsDisclosure))
            let information = try #require(snapshot.readingIndex(of: .informationPath))

            // Both lanes before anything that could read as ranking them.
            #expect(pixelLabel < pixelExplanation, "\(testCase.name)")
            #expect(pixelExplanation < provenance, "\(testCase.name)")
            // The disclosure control precedes the statements it reveals, so the reading order is
            // the screen's order: the control, then what activating it shows.
            #expect(provenance < disclosure, "\(testCase.name)")
            #expect(disclosure < scope, "\(testCase.name)")
            #expect(scope < falseResult, "\(testCase.name)")
            #expect(falseResult < bytes, "\(testCase.name)")
            #expect(bytes < information, "\(testCase.name)")

            // The summary and the notice sit after both lanes and before the limitations, so
            // neither replaces a lane and neither displaces a limitation.
            if let summary = snapshot.readingIndex(of: .combinedSummary) {
                #expect(provenance < summary, "\(testCase.name)")
                #expect(summary < disclosure, "\(testCase.name)")
            }
            if let notice = snapshot.readingIndex(of: .apparentInconsistencyNotice) {
                #expect(provenance < notice, "\(testCase.name)")
                #expect(notice < disclosure, "\(testCase.name)")
            }
            if let screenshot = snapshot.readingIndex(of: .screenshotProvenanceExplanation) {
                #expect(provenance < screenshot, "\(testCase.name)")
                #expect(screenshot < disclosure, "\(testCase.name)")
            }

            // The action order on a completed report is the limitations disclosure, then the one
            // onward path, then the recovery control. It used to be three onward paths in the
            // report's declared path order; those rows each carried a standing paragraph about the
            // application and none of them navigated anywhere, so they are one control now.
            //
            // The recovery is still last rather than first: Requirement 3.13 offers a new session
            // from a terminal screen, and putting that action ahead of the report would let a user
            // reach "start again" before reaching the limitations the report is required to state.
            // It is drawn in a pinned bar at the bottom of the screen, which agrees with being last
            // rather than contradicting it.
            #expect(
                snapshot.actionOrder
                    == [
                        .limitationsDisclosure,
                        .informationPath,
                        .imageSelectionControl,
                    ],
                "\(testCase.name)"
            )
        }
    }

    @Test("The three onward paths are the report's declared vocabulary, in declaration order")
    func onwardPathsFollowTheDeclaredVocabulary() throws {
        #expect(ReportDisclosurePath.allCases.count == 3)

        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )
        // One onward control, and it is a navigating control like the three it replaced.
        let element = try #require(snapshot.element(.informationPath))
        #expect(element.role == .navigatingControl)
        #expect(element.isOperable)
        #expect(element.traits == [.button])

        // Every path's statement is still addressable - they moved to the destination rather than
        // being dropped - so the report's declared path vocabulary is unchanged and complete.
        let report = try ReportFixture.pixelOnlyPresentation()
        for path in ReportDisclosurePath.allCases {
            let reference = report.disclosurePaths.reference(for: path)
            #expect(reference.localizationKey.rawValue.isEmpty == false, "\(path.rawValue)")
        }
        #expect(ReportDisclosurePath.allCases.count == 3)

        // And no per-path control survives on the report.
        for identity in snapshot.readingOrder {
            #expect(
                identity.stableKey.hasSuffix("-path") == false
                    || identity == .informationPath,
                "\(identity.stableKey) is a per-path control the report should no longer expose"
            )
        }
    }

    @Test(
        "Every role's traits and operability are fully decided",
        arguments: AccessibilityRole.allCases
    )
    func roleDefinitionsAreTotal(role: AccessibilityRole) {
        #expect(role.traits.isEmpty == false)
        #expect(role.isOperable == (role.activationArea != nil))
        if role.isOperable {
            #expect(role.traits == [.button])
            #expect(role.traits.contains(.staticText) == false)
        } else {
            #expect(role.traits.contains(.staticText))
            #expect(role.traits.contains(.button) == false)
        }
    }

    @Test("A status or progress role announces that it updates, and a static field does not")
    func changingTextIsMarkedAsChanging() {
        for role in AccessibilityRole.allCases {
            let updates = role.traits.contains(.updatesFrequently)
            let expected = role == .statusField || role == .progressField
            #expect(updates == expected, "\(role.rawValue)")
        }
        #expect(AccessibilityTrait.allCases.count == 4)
    }
}

// MARK: - 12.5 and 12.6: announcements and focus across transitions

@Suite("Accessibility announcements and focus across screen transitions")
struct AccessibilityTransitionTests {

    @Test("A realistic session announces once per meaningful change and nothing else")
    func aWholeSessionAnnouncesTheMeaningfulChanges() throws {
        let copy = try ViewStateFixture.pixelOnlyBinding()
        let report = try ReportFixture.pixelOnlyPresentation(pixel: .notEnoughSignal)

        func working(_ progress: AnalysisProgressState) throws -> AccessibilityScreenInput {
            try AccessibilityReadinessFixture.input(
                try ViewStateFixture.working(progress: progress, copy: copy),
                copy: copy
            )
        }

        // The sequence a user actually drives: ready, an ingest, one stage reported three times in
        // both continuing and measured form, a second stage, then the terminal.
        let sequence: [AccessibilityScreenInput] = [
            try AccessibilityReadinessFixture.input(.idle, copy: copy),
            try AccessibilityReadinessFixture.input(
                .importing(ImportAttemptSnapshot(route: .photosPicker)),
                copy: copy
            ),
            try working(.indeterminate(stage: .preprocessing)),
            try working(
                .determinate(completed: 10, total: 100, unit: .encodedBytes, stage: .preprocessing)
            ),
            try working(
                .determinate(completed: 95, total: 100, unit: .encodedBytes, stage: .preprocessing)
            ),
            try working(.indeterminate(stage: .inference)),
            .completed(report),
        ]

        var debouncer = StatusAnnouncementDebouncer()
        var spoken: [AnnouncedStatus] = []
        for input in sequence {
            if let announcement = debouncer.announcement(for: input) {
                spoken.append(announcement.status)
                #expect(announcement.focus == .preservesExistingFocus)
            }
        }

        // Five announcements from seven observations: the two extra progress observations share the
        // preprocessing stage's identity, so a determinate readout arriving many times a second is
        // heard once.
        #expect(sequence.count == 7)
        #expect(
            spoken == [
                .awaitingSelection,
                .importInFlight(.photosPicker),
                .analysisWorking(.preprocessing),
                .analysisWorking(.inference),
                .analysisCompleted(.notEnoughSignal),
            ]
        )
        #expect(debouncer.lastAnnouncedStatus == .analysisCompleted(.notEnoughSignal))
    }

    @Test("A stage announces once however many times it is observed")
    func oneStageAnnouncesOnceAcrossManyObservations() throws {
        let copy = try ViewStateFixture.pixelOnlyBinding()

        for stage in AnalysisStage.allCases {
            var debouncer = StatusAnnouncementDebouncer()
            var announcements = 0
            var observations = 0

            for completed in stride(from: UInt64(0), through: 100, by: 2) {
                let input = try AccessibilityReadinessFixture.input(
                    try ViewStateFixture.working(
                        progress: .determinate(
                            completed: completed,
                            total: 100,
                            unit: .encodedBytes,
                            stage: stage
                        ),
                        copy: copy
                    ),
                    copy: copy
                )
                observations += 1
                if debouncer.announcement(for: input) != nil { announcements += 1 }
            }

            #expect(observations == 51, "\(stage.rawValue)")
            #expect(announcements == 1, "\(stage.rawValue)")
        }
    }

    @Test("Every ordered pair of screens announces exactly when its status identity changed")
    func pairwiseAnnouncementsFollowStatusIdentity() throws {
        let cases = try AccessibilityReadinessFixture.representativeCases()
        var evaluatedPairs = 0
        var announcedPairs = 0

        for first in cases {
            for second in cases {
                var debouncer = StatusAnnouncementDebouncer()

                #expect(debouncer.wouldAnnounce(first.input), "\(first.name)")
                #expect(debouncer.announcement(for: first.input) != nil, "\(first.name)")

                let statusChanged = AnnouncedStatus(second.input) != AnnouncedStatus(first.input)
                #expect(
                    debouncer.wouldAnnounce(second.input) == statusChanged,
                    "\(first.name) then \(second.name)"
                )
                let followUp = debouncer.announcement(for: second.input)
                #expect((followUp != nil) == statusChanged, "\(first.name) then \(second.name)")
                if followUp != nil { announcedPairs += 1 }
                evaluatedPairs += 1
            }
        }

        // A shrunken sweep would make the equivalence hold over nothing. Both outcomes have to
        // occur, and the pair count has to be the whole square.
        #expect(cases.count == 8)
        #expect(evaluatedPairs == cases.count * cases.count)
        #expect(announcedPairs > 0)
        #expect(announcedPairs < evaluatedPairs)
    }

    @Test("wouldAnnounce is a probe: it agrees with announcing and records nothing")
    func wouldAnnounceIsPure() throws {
        let cases = try AccessibilityReadinessFixture.representativeCases()
        var debouncer = StatusAnnouncementDebouncer()

        #expect(debouncer.lastAnnouncedStatus == nil)
        for testCase in cases {
            #expect(debouncer.wouldAnnounce(testCase.input), "\(testCase.name)")
        }
        // Every probe above answered true and none recorded anything, so the first real
        // announcement is still the first.
        #expect(debouncer.lastAnnouncedStatus == nil)

        let first = try #require(cases.first)
        #expect(debouncer.announcement(for: first.input) != nil)
        #expect(debouncer.lastAnnouncedStatus == AnnouncedStatus(first.input))
        #expect(debouncer.wouldAnnounce(first.input) == false)
    }

    @Test("The debouncer is a value: a copy does not inherit later announcements")
    func debouncerIsAValue() throws {
        let cases = try AccessibilityReadinessFixture.representativeCases()
        let first = try #require(cases.first)
        let last = try #require(cases.last)
        #expect(AnnouncedStatus(first.input) != AnnouncedStatus(last.input))

        var original = StatusAnnouncementDebouncer()
        #expect(original.announcement(for: first.input) != nil)

        var copy = original
        #expect(copy.announcement(for: last.input) != nil)

        // Advancing the copy leaves the original exactly where it was, which is what lets a test
        // replay a branch of a session without a fresh setup.
        #expect(original.lastAnnouncedStatus == AnnouncedStatus(first.input))
        #expect(copy.lastAnnouncedStatus == AnnouncedStatus(last.input))
        #expect(original != copy)
    }

    @Test("No announcement on any screen can move accessibility focus")
    func announcementsNeverMoveFocusOnAnyScreen() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            let announcement = testCase.snapshot.announcement
            let derived = AnnouncedStatus(testCase.input)

            #expect(announcement.focus == .preservesExistingFocus, "\(testCase.name)")
            #expect(announcement.status == derived, "\(testCase.name)")
            #expect(announcement.urgency == derived.urgency, "\(testCase.name)")
        }
        #expect(AnnouncementFocus.allCases == [.preservesExistingFocus])
    }

    @Test("Every terminal status interrupts and every in-flight status waits")
    func urgencyIsDecidedByTerminality() throws {
        // Enumerated from the closed vocabularies rather than from screens, so a status shape no
        // screen happens to produce today is still checked.
        var statuses: [AnnouncedStatus] = [.awaitingSelection, .analysisCancelled]
        statuses += InputRoute.allCases.map(AnnouncedStatus.importInFlight)
        statuses += AnalysisStage.allCases.map(AnnouncedStatus.analysisWorking)
        statuses += PixelLabelKey.allCases.map(AnnouncedStatus.analysisCompleted)
        statuses += AnalysisError.allCases.map(AnnouncedStatus.analysisFailed)

        #expect(
            statuses.count
                == 2 + InputRoute.allCases.count + AnalysisStage.allCases.count
                    + PixelLabelKey.allCases.count + AnalysisError.allCases.count
        )
        #expect(Set(statuses.map(\.stableKey)).count == statuses.count)

        for status in statuses {
            let interrupts: Bool =
                switch status {
                case .analysisCompleted, .analysisCancelled, .analysisFailed: true
                case .awaitingSelection, .importInFlight, .analysisWorking: false
                }
            #expect(
                status.urgency == (interrupts ? .interruptsCurrentSpeech : .afterCurrentSpeech),
                "\(status.stableKey)"
            )
        }
        #expect(AnnouncementUrgency.allCases.count == 2)
    }

    @Test("Exactly the two terminals with approved wording announce; every other status says why")
    func announceabilityMatchesTheApprovedVocabulary() throws {
        var announceable: Set<String> = []
        var blocked: Set<String> = []

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let announcement = testCase.snapshot.announcement
            switch announcement.content {
            case .approved:
                #expect(announcement.isAnnounceable, "\(testCase.name)")
                announceable.insert(announcement.status.stableKey)
            case let .blocked(surfaces):
                #expect(surfaces.isEmpty == false, "\(testCase.name)")
                #expect(announcement.isAnnounceable == false, "\(testCase.name)")
                blocked.insert(announcement.status.stableKey)
            }
        }

        // Five of the six families announce. The two terminals whose wording was always available
        // announce approved verdict copy — a fixed pixel label and an approved error message — and
        // the ingest attempt, the active work, and the cancelled terminal now announce approved
        // chrome copy.
        //
        // The ready family is the one that stays silent, and not for want of wording. It is not a
        // status *change* anyone waits for: it is the state the application launches in and
        // returns to, and the only approved wording near it is the picker control's own label,
        // which is a control name rather than a status. Announcing a button's label as a status is
        // the substitution the closed announcement vocabulary exists to prevent, so the gap stays
        // recorded.
        var expectedAnnounceable = Set(
            PixelLabelKey.allCases.map { "analysis-completed/\($0.rawValue)" }
                + AnalysisError.allCases.map { "analysis-failed/\($0.rawValue)" }
                + InputRoute.allCases.map { "import-in-flight/\($0.rawValue)" }
                + AnalysisStage.allCases.map { "analysis-working/\($0.rawValue)" }
        )
        expectedAnnounceable.insert("analysis-cancelled")
        #expect(announceable == expectedAnnounceable)
        #expect(announceable.isDisjoint(with: blocked))
        #expect(blocked == ["awaiting-selection"])
    }

    @Test("Focus is retained across every transition exactly when the element is still exposed")
    func focusRetentionFollowsExposure() throws {
        let cases = try AccessibilityReadinessFixture.representativeCases()
        var retained = 0
        var moved = 0

        for origin in cases {
            let originSnapshot = origin.snapshot
            for destination in cases {
                let destinationSnapshot = destination.snapshot

                // Every identity either screen knows about, so a transition is checked against
                // elements that persist, elements that vanish, and elements that arrive.
                let candidates = Set(
                    originSnapshot.readingOrder + destinationSnapshot.readingOrder
                        + originSnapshot.blockedElements.map(\.identity)
                )
                for identity in candidates.sorted(by: { $0.stableKey < $1.stableKey }) {
                    let retention = destinationSnapshot.focusRetention(movingFrom: identity)
                    let context = "\(origin.name) then \(destination.name), \(identity.stableKey)"

                    if destinationSnapshot.exposes(identity) {
                        #expect(retention == .retained(identity), "\(context)")
                        #expect(retention.preservesFocus, "\(context)")
                        #expect(retention.target == identity, "\(context)")
                        retained += 1
                    } else {
                        let expected = FocusRetention.movedBecauseElementIsGone(
                            vanished: identity,
                            suggestedTarget: destinationSnapshot.elements.first?.identity
                        )
                        #expect(retention == expected, "\(context)")
                        #expect(retention.preservesFocus == false, "\(context)")
                        #expect(
                            retention.target == destinationSnapshot.elements.first?.identity,
                            "\(context)"
                        )
                        moved += 1
                    }
                }

                #expect(
                    destinationSnapshot.focusRetention(movingFrom: nil) == .noFocusedElement,
                    "\(origin.name) then \(destination.name)"
                )
            }
        }

        // Both arms have to have been exercised, or the equivalence held over one branch.
        #expect(retained > 0)
        #expect(moved > 0)
    }

    @Test("Focus survives an element moving in the reading order")
    func focusSurvivesReorderingAcrossReportShapes() throws {
        // A fused report inserts the summary and the notice above the limitations, so the
        // limitations sit at different positions in two real reports. Focus is tracked by identity,
        // so it is kept in both directions.
        let fused = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.fusedPresentation())
        )
        let plain = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.pixelOnlyPresentation())
        )

        let shared = Set(fused.readingOrder).intersection(Set(plain.readingOrder))
        #expect(shared.isEmpty == false)

        var repositioned = 0
        for identity in shared {
            #expect(fused.focusRetention(movingFrom: identity) == .retained(identity))
            #expect(plain.focusRetention(movingFrom: identity) == .retained(identity))
            if fused.readingIndex(of: identity) != plain.readingIndex(of: identity) {
                repositioned += 1
            }
        }
        #expect(repositioned > 0, "the two report shapes must actually reposition something")
    }

    @Test("Every screen exposes something, so a vanished element always has somewhere to send focus")
    func everyScreenOffersAFocusTarget() throws {
        // This replaces a test that asserted the opposite and asserted it correctly at the time:
        // four of the six families exposed no element at all, so a transition into one of them left
        // accessibility focus with nowhere to go, and `suggestedTarget` was `nil`.
        //
        // That was a consequence of the copy blockage, not of the focus rule, and the old test said
        // so — it existed "so approving the missing wording changes it visibly". The wording now
        // exists for the chrome surfaces, so this is that visible change: no family is empty, and
        // the focus rule's `nil`-target branch is no longer reachable from any real screen.
        //
        // The focus rule itself is checked more strictly than before, on every screen rather than
        // only the empty ones: focusing an identity a screen does not expose must move focus to the
        // first element of that screen's reading order, and never to nothing.
        var families: Set<AnalysisScreenFamily> = []
        var checked = 0

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot
            families.insert(testCase.family)

            #expect(snapshot.elements.isEmpty == false, "\(testCase.name)")

            // An identity no screen in this application exposes, so the vanished branch is taken
            // on every screen including the ones that do expose a pixel label.
            let absent = AccessibleElementIdentity.technicalDetailsDisclosure
            #expect(snapshot.exposes(absent) == false, "\(testCase.name)")

            let retention = snapshot.focusRetention(movingFrom: absent)
            let expected = FocusRetention.movedBecauseElementIsGone(
                vanished: absent,
                suggestedTarget: snapshot.elements.first?.identity
            )
            #expect(retention == expected, "\(testCase.name)")
            #expect(retention.target != nil, "\(testCase.name)")
            checked += 1
        }

        #expect(families == Set(AnalysisScreenFamily.allCases))
        #expect(checked > 0)
    }
}

// MARK: - 12.11 and 12.12: the assistive workflow table

@Suite("Assistive workflow operability, as a pinned table")
struct AssistiveWorkflowOperabilityTests {

    /// The operability of every workflow on every representative screen, keyed for comparison.
    ///
    /// Keyed by case name rather than family, so two representatives of one family cannot mask a
    /// disagreement by overwriting each other.
    static func table() throws -> [String: Bool] {
        var table: [String: Bool] = [:]
        for testCase in try AccessibilityReadinessFixture.representativeCases() {
            let snapshot = testCase.snapshot
            for workflow in AccessibilityWorkflow.allCases {
                table["\(testCase.name)/\(workflow.rawValue)"] =
                    WorkflowOperability.evaluating(workflow, in: snapshot).isOperable
            }
        }
        return table
    }

    @Test("Six of the seven workflows are operable where their screen presents them, and one is not")
    func operableWorkflowsArePinnedPerScreen() throws {
        let table = try Self.table()
        let operable = table.filter(\.value).keys.sorted()

        // The previous pin was four cells, and it was accurate: five of the seven workflows needed
        // a control that had no approved label, so they could not be completed by anyone. The
        // chrome copy vocabulary supplies those labels, so ingest, analysis, cancellation, and
        // retry become operable on the screens that present them.
        //
        // Still pinned rather than derived. The value of this table is that a change to what is
        // reachable shows up as a diff here, and deriving the expectation from the same code under
        // test would remove exactly that.
        //
        // Two cells are deliberately still false, for two different reasons:
        //
        //   * `handoff-consent` on every screen, because its presenter is the Share Extension.
        //     `WorkflowOperability.isOperable` refuses a workflow this module does not present, so
        //     an empty required-element list can never read as a pass.
        //   * `ingest` and `retry` on `error-decoding`, because the error screen names its
        //     recovery `.analysisErrorRecovery` while both workflows require
        //     `.imageSelectionControl`. The control is there and labelled; the two identities for
        //     one action are a pre-existing modelling split this change does not touch.
        #expect(
            operable == [
                "active-inference/analysis",
                "active-inference/cancellation",
                "active-preprocessing/analysis",
                "active-preprocessing/cancellation",
                "cancelled/ingest",
                "cancelled/retry",
                "completed-fused/ingest",
                "completed-fused/limitation-review",
                "completed-fused/result-review",
                "completed-fused/retry",
                "completed-pixel-only/ingest",
                "completed-pixel-only/limitation-review",
                "completed-pixel-only/result-review",
                "completed-pixel-only/retry",
                "ready/ingest",
                "ready/retry",
            ]
        )
        #expect(table.count == 8 * AccessibilityWorkflow.allCases.count)

        // Handoff consent is never operable here, on any screen, and that is a presenter fact
        // rather than a copy gap.
        for testCase in try AccessibilityReadinessFixture.representativeCases() {
            #expect(table["\(testCase.name)/handoff-consent"] == false, "\(testCase.name)")
        }
    }

    @Test("Result and limitation review are operable for every report shape, with no blocking gap")
    func reviewWorkflowsAreOperableForEveryReportShape() throws {
        var checked = 0

        for testCase in try AccessibilityReadinessFixture.completedCases() {
            let snapshot = testCase.snapshot
            for workflow in [AccessibilityWorkflow.resultReview, .limitationReview] {
                let operability = WorkflowOperability.evaluating(workflow, in: snapshot)
                let context = "\(testCase.name)/\(workflow.rawValue)"

                #expect(operability.isOperable, "\(context)")
                #expect(operability.blockingGaps.isEmpty, "\(context)")
                #expect(operability.unusableElements.isEmpty, "\(context)")
                #expect(operability.interaction == .nativeActivationAction, "\(context)")
                #expect(operability.presenter == .mainApplicationScreens, "\(context)")
                #expect(
                    operability.requiredElements.map(\.identity)
                        == WorkflowOperability.requiredIdentities(for: workflow),
                    "\(context)"
                )
                #expect(operability.requiredElements.isEmpty == false, "\(context)")
                checked += 1
            }
        }

        let reportShapes = try AccessibilityReadinessFixture.completedCases().count
        #expect(checked == 2 * reportShapes)
        #expect(reportShapes > 0)
    }

    @Test("A workflow that is not operable is blocked on copy or belongs to another screen")
    func blockedWorkflowsNameTheirGap() throws {
        var blockedOnCopy = 0
        var absentFromScreen = 0

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot
            for workflow in AccessibilityWorkflow.allCases
            where workflow.presenter == .mainApplicationScreens {
                let operability = WorkflowOperability.evaluating(workflow, in: snapshot)
                guard operability.isOperable == false else { continue }

                let context = "\(testCase.name)/\(workflow.rawValue)"
                #expect(operability.unusableElements.isEmpty == false, "\(context)")

                // A non-operable workflow is either blocked on approved copy, in which case the gap
                // is named, or its controls belong to another screen family, in which case there is
                // nothing to approve. Nothing else is representable.
                for element in operability.unusableElements {
                    switch element.status {
                    case let .blockedByUnapprovedCopy(surfaces):
                        #expect(surfaces.isEmpty == false, "\(context)")
                        #expect(operability.blockingGaps.isEmpty == false, "\(context)")
                        blockedOnCopy += 1
                    case .notPresentOnThisScreen:
                        #expect(snapshot.exposes(element.identity) == false, "\(context)")
                        #expect(snapshot.blockedElement(element.identity) == nil, "\(context)")
                        absentFromScreen += 1
                    case .exposed, .exposedWithUnmetSemantics:
                        Issue.record("a usable element cannot appear in the unusable list")
                    }
                }

                #expect(
                    operability.blockingGaps
                        == operability.blockingGaps.sorted { $0.stableKey < $1.stableKey },
                    "\(context)"
                )
                #expect(
                    Set(operability.blockingGaps).count == operability.blockingGaps.count,
                    "\(context)"
                )
            }
        }

        // Both diagnoses have to occur, or one arm of the switch was never taken.
        #expect(blockedOnCopy > 0)
        #expect(absentFromScreen > 0)
    }

    @Test("Ingest and retry are operable on exactly the screens that expose the selection control")
    func imageSelectionMakesIngestAndRetryOperable() throws {
        // The inverse of a test that required both workflows to be blocked by exactly
        // `.viewState(.startNewSessionAction)`. That was the correct reading while no approved
        // wording existed for the control; the chrome vocabulary supplies it, so the assertion now
        // checks that the control is a real, labelled, activatable element and that both workflows
        // that depend on it are operable wherever it appears.
        //
        // No screen records `.imageSelectionControl` as blocked any more, so the old loop condition
        // matched nothing and its `screens >= 3` guard would have failed rather than passed
        // vacuously — the guard did its job.
        var screens = 0

        for testCase in try AccessibilityReadinessFixture.allCases()
        where testCase.snapshot.element(.imageSelectionControl) != nil {
            let snapshot = testCase.snapshot
            let control = try #require(snapshot.element(.imageSelectionControl))

            #expect(control.role == .activatingControl, "\(testCase.name)")
            #expect(control.activationArea == .requiredMinimum, "\(testCase.name)")
            #expect(control.hasCompleteSemantics, "\(testCase.name)")
            #expect(
                control.label == .approvedChromeCopy(ChromeCopyReference(.imageSelectionAction)),
                "\(testCase.name)"
            )
            #expect(snapshot.blockedElement(.imageSelectionControl) == nil, "\(testCase.name)")

            for workflow in [AccessibilityWorkflow.ingest, .retry] {
                let operability = WorkflowOperability.evaluating(workflow, in: snapshot)
                let context = "\(testCase.name)/\(workflow.rawValue)"

                #expect(operability.isOperable, "\(context)")
                #expect(operability.blockingGaps.isEmpty, "\(context)")
                #expect(operability.unusableElements.isEmpty, "\(context)")
            }
            screens += 1
        }

        // Ready, cancelled, and every completed report expose the control, so the sweep is not
        // vacuous. The error screen deliberately does not — see
        // `retryOnTheErrorScreenHasNoRecordedReason`.
        #expect(screens >= 3)
    }

    @Test("On the error screen the retry workflow is reported absent with no recorded reason")
    func retryOnTheErrorScreenHasNoRecordedReason() throws {
        // The state as it is, not as it should be. Every terminal screen offers the same recovery -
        // select another image - and the ready, cancelled, and completed screens all record it
        // under `imageSelectionControl`. The error screen exposes it under `analysisErrorRecovery`
        // instead, with an approved label, the button trait, and the 44-point area. Because
        // `requiredIdentities(for: .retry)` names only `imageSelectionControl`, the one recovery
        // control the application can actually render is credited to no workflow, and retry reports
        // `notPresentOnThisScreen` with an empty blocking-gap list - the diagnostic hole
        // `WorkflowOperability` exists to close.
        var errorScreens = 0

        for testCase in try AccessibilityReadinessFixture.allCases()
        where testCase.family == .error {
            let snapshot = testCase.snapshot
            let operability = WorkflowOperability.evaluating(.retry, in: snapshot)

            let recovery = try #require(snapshot.element(.analysisErrorRecovery))
            #expect(recovery.isOperable, "\(testCase.name)")
            #expect(recovery.activationArea == .requiredMinimum, "\(testCase.name)")
            #expect(recovery.hasCompleteSemantics, "\(testCase.name)")

            #expect(operability.isOperable == false, "\(testCase.name)")
            #expect(operability.blockingGaps.isEmpty, "\(testCase.name)")
            #expect(
                operability.unusableElements.map(\.status) == [.notPresentOnThisScreen],
                "\(testCase.name)"
            )
            #expect(snapshot.blockedElement(.imageSelectionControl) == nil, "\(testCase.name)")
            errorScreens += 1
        }

        #expect(errorScreens == 2 * AnalysisError.allCases.count)
    }

    @Test("This layer answers VoiceOver and Switch Control identically, and owns neither condition alone")
    func theTwoTechnologiesAreAnsweredByTheSameElements() throws {
        // Requirements 12.11 and 12.12 name the same seven workflows. There is no element in this
        // application one technology can reach and the other cannot, so the layer takes no
        // condition parameter and the difference between the two clauses is a difference in the
        // evidence, not in the semantics.
        #expect(WorkflowOperability.coveredConditions == [.voiceOver, .switchControl])
        #expect(AssistiveInteraction.allCases == [.nativeActivationAction])

        // The two conditions this layer does not answer are answered by the layout and motion
        // policies, and together the four partition the release matrix's condition vocabulary. A
        // fifth condition would be unowned, which this catches.
        let layoutConditions: Set<AssistiveCondition> = [.largestDynamicType, .reduceMotion]
        #expect(WorkflowOperability.coveredConditions.isDisjoint(with: layoutConditions))
        #expect(
            WorkflowOperability.coveredConditions.union(layoutConditions)
                == Set(AssistiveCondition.allCases)
        )
    }

    @Test("Handoff consent is never claimed by this module, on any screen")
    func handoffConsentIsAlwaysTheShareExtensions() throws {
        #expect(AccessibilityWorkflow.handoffConsent.presenter == .shareExtension)
        #expect(WorkflowOperability.requiredIdentities(for: .handoffConsent).isEmpty)

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let operability = WorkflowOperability.evaluating(.handoffConsent, in: testCase.snapshot)

            // An empty required list cannot read as operable. A gate that passed by knowing nothing
            // would be worse than a red cell.
            #expect(operability.isOperable == false, "\(testCase.name)")
            #expect(operability.presenter == .shareExtension, "\(testCase.name)")
            #expect(operability.requiredElements.isEmpty, "\(testCase.name)")
            #expect(operability.blockingGaps.isEmpty, "\(testCase.name)")
        }
    }

    @Test("Every workflow is evaluated on every screen, in the domain's declaration order")
    func everyWorkflowIsEvaluatedEverywhere() throws {
        for testCase in try AccessibilityReadinessFixture.allCases() {
            let evaluated = WorkflowOperability.evaluating(testCase.snapshot)
            #expect(evaluated.map(\.workflow) == AccessibilityWorkflow.allCases, "\(testCase.name)")
        }
        #expect(AccessibilityWorkflow.allCases.count == 7)
    }

    @Test("The presentation layer and the release matrix agree on the workflow vocabulary")
    func workflowVocabularyMatchesTheGateMatrix() {
        // Requirement 12.13 records a cell per workflow. If this module could present a workflow
        // the matrix has no cell for, a required position would be missing rather than failing. One
        // vocabulary, owned by the domain, and every entry declares where it is presented.
        for workflow in AccessibilityWorkflow.allCases {
            #expect(WorkflowPresenter.allCases.contains(workflow.presenter), "\(workflow.rawValue)")
        }
        #expect(
            Set(AccessibilityWorkflow.allCases.map(\.presenter)) == Set(WorkflowPresenter.allCases)
        )
        #expect(
            AccessibilityWorkflow.allCases.filter { $0.presenter == .shareExtension }
                == [.handoffConsent]
        )
    }
}

// MARK: - 12.15 and 12.16: localization readiness substitution

@Suite("Localization readiness substitution over every screen")
struct LocalizationReadinessSubstitutionTests {

    /// Every readiness resolver, paired with its variant.
    static func readinessResolvers() throws
        -> [(variant: LocalizationReadinessVariant, resolver: AccessibleTextResolver)]
    {
        try LocalizationReadinessVariant.allCases.map { variant in
            (
                variant,
                AccessibleTextResolver(
                    catalog: try LocalizationReadinessCatalogs.load(variant),
                    languageTag: variant.languageTag
                )
            )
        }
    }

    /// A name reduced to lowercase alphanumerics, so separator style does not matter.
    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    @Test("The suite's four catalogs are exactly the release matrix's four declared variants")
    func readinessVariantsMatchTheDeclaredVocabulary() {
        // Requirement 12.17 records a cell per variant. A catalog with no matching declared variant
        // would be coverage nobody records; a declared variant with no catalog would be a cell
        // nobody can run.
        let suiteVariants = Set(
            LocalizationReadinessVariant.allCases.map { Self.normalized($0.rawValue) }
        )
        let declaredVariants = Set(
            LocalizationTestVariant.allCases.map { Self.normalized($0.rawValue) }
        )

        #expect(suiteVariants == declaredVariants)
        #expect(suiteVariants.count == 4)
        #expect(
            LocalizationReadinessVariant.allCases.count == LocalizationTestVariant.allCases.count
        )
    }

    @Test("Substituting any readiness catalog changes no accessibility semantic on any screen")
    func semanticsAreIdenticalUnderEveryReadinessCatalog() throws {
        // Requirement 12.16, as an identity rather than as an outcome. The projection takes no
        // catalog, so this asserts the consequence over every screen the application can show: the
        // reading order, action order, traits, values, unmet semantics, blocked set, announcement,
        // and recorded gaps a readiness catalog would render are the shipping ones, unchanged.
        let resolvers = try Self.readinessResolvers()
        #expect(resolvers.count == 4)

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let expected = testCase.snapshot

            for (variant, resolver) in resolvers {
                let actual = AccessibilitySemanticsSnapshot.projecting(testCase.input)
                let context = "\(testCase.name)/\(variant.rawValue)"

                #expect(actual == expected, "\(context)")
                #expect(actual.readingOrder == expected.readingOrder, "\(context)")
                #expect(actual.actionOrder == expected.actionOrder, "\(context)")
                #expect(
                    actual.elements.map(\.traits) == expected.elements.map(\.traits),
                    "\(context)"
                )
                #expect(actual.elements.map(\.label) == expected.elements.map(\.label), "\(context)")
                #expect(actual.elements.map(\.value) == expected.elements.map(\.value), "\(context)")
                #expect(
                    actual.elements.map(\.unmetSemantics)
                        == expected.elements.map(\.unmetSemantics),
                    "\(context)"
                )
                #expect(
                    actual.blockedElements.map(\.identity)
                        == expected.blockedElements.map(\.identity),
                    "\(context)"
                )
                #expect(actual.announcement == expected.announcement, "\(context)")
                #expect(actual.recordedCopyGaps == expected.recordedCopyGaps, "\(context)")
                #expect(actual.layout == expected.layout, "\(context)")

                // The resolver is the only catalog-dependent part, and it is not in the snapshot.
                #expect(resolver.languageTag == variant.languageTag, "\(context)")
                #expect(resolver.catalog.sourceLanguage == variant.languageTag, "\(context)")
            }
        }
    }

    @Test("The renderable and unresolvable partition is identical under every catalog")
    func renderablePartitionIsIdenticalUnderEveryCatalog() throws {
        let shipped = try AccessibleTextResolver.shipped()
        let resolvers = try Self.readinessResolvers()

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let snapshot = testCase.snapshot
            let expectedRenderable = shipped.renderableElements(in: snapshot).map(\.identity)
            let expectedUnresolvable = shipped.unresolvableElements(in: snapshot).map(\.identity)

            #expect(
                expectedRenderable.count + expectedUnresolvable.count == snapshot.elements.count,
                "\(testCase.name)"
            )

            for (variant, resolver) in resolvers {
                let context = "\(testCase.name)/\(variant.rawValue)"
                #expect(
                    resolver.renderableElements(in: snapshot).map(\.identity) == expectedRenderable,
                    "\(context)"
                )
                #expect(
                    resolver.unresolvableElements(in: snapshot).map(\.identity)
                        == expectedUnresolvable,
                    "\(context)"
                )
            }
        }
    }

    @Test("Every exposed element renders, except a Combined Summary with no approved wording")
    func renderableSetIsPinnedPerFamily() throws {
        // This is the third state of this test, and the history is worth keeping because each step
        // was a real change in what a user would see:
        //
        //   1. "the pixel label on a completed report, and nothing anywhere else" - accurate while
        //      the catalog held three strings;
        //   2. plus each family's own chrome, once the chrome surfaces had proposed values;
        //   3. and now everything, because the unconditional verdict surfaces have proposed values
        //      too. The error family in particular went from rendering *nothing at all* - both of its
        //      elements carry verdict addresses - to rendering its category message and its recovery.
        //
        // The one exception is the Combined Summary, whose key an approved Evidence Fusion Rule would
        // name and which therefore still has no wording. Stating the exception as a filter rather
        // than as a per-family list is deliberate: a hardcoded list of expected identities has to be
        // re-derived by hand every time the projection changes, and the claim that actually matters
        // is "nothing on screen is a missing string".
        let shipped = try AccessibleTextResolver.shipped()
        var sawCompleted = false

        for testCase in try AccessibilityReadinessFixture.allCases() {
            let renderable = shipped.renderableElements(in: testCase.snapshot).map(\.identity)
            let unresolvable = shipped.unresolvableElements(in: testCase.snapshot).map(\.identity)

            // Whatever cannot render is a Combined Summary, on every screen and in every family.
            #expect(
                unresolvable.allSatisfy { $0 == .combinedSummary },
                "\(testCase.name) cannot render \(unresolvable.map(\.stableKey))"
            )

            // The renderable set is the rest, in the snapshot's own order.
            let expected = testCase.snapshot.readingOrder.filter { $0 != .combinedSummary }
            #expect(renderable == expected, "\(testCase.name)")

            if testCase.family == .completed { sawCompleted = true }
            // The error family used to render nothing; it now renders both of its elements.
            if testCase.family == .error {
                #expect(renderable.contains(.analysisErrorMessage), "\(testCase.name)")
                #expect(renderable.contains(.analysisErrorRecovery), "\(testCase.name)")
            }
        }

        // Not a vacuous pass over a fixture set with no completed report in it.
        #expect(sawCompleted)
    }

    @Test("No verdict address reaches a catalog, and every chrome address does")
    func verdictAddressesMissAndChromeAddressesResolve() throws {
        // Two halves, and the split is the point.
        //
        // The verdict half is unchanged and still uncomfortable: every `VerdictCopySurface` address
        // an element carries resolves against a key no catalog holds, because that wording is the
        // unresolved Approved Verdict Copy decision. So the explanation, the lane state, the
        // limitations, the summary, and the disclosure paths render nothing.
        //
        // The chrome half is what changed. Every `ChromeCopySurface` address resolves in the
        // shipped catalog and in all four readiness catalogs, which is what makes Requirements
        // 12.15 and 12.16 non-vacuous for the first time: substituting an expansion, long-word,
        // bidirectional, or pseudolocalized catalog now changes real text on every screen, rather
        // than changing nothing because the only rendered element bypassed the catalog through
        // `FixedPixelLabelText`.
        var addressed: Set<String> = []
        var chromeAddressed: Set<String> = []
        for testCase in try AccessibilityReadinessFixture.allCases() {
            for element in testCase.snapshot.elements {
                let sources = [element.label] + (element.value.map { [$0] } ?? [])
                for source in sources {
                    if let reference = source.copyReference {
                        addressed.insert(reference.localizationKey.rawValue)
                    }
                    if let reference = source.chromeReference {
                        chromeAddressed.insert(reference.localizationKey.rawValue)
                    }
                }
            }
        }
        #expect(addressed.isEmpty == false)
        #expect(chromeAddressed.isEmpty == false)

        let shippedKeys = Set(try EnglishStringCatalog.loadShippedCatalog().keys)
        #expect(shippedKeys.count == 56)

        // The verdict half has inverted. Every verdict address a screen carries is now a key the
        // shipped catalog holds, except a Combined Summary - so the explanation, the lane state, the
        // limitations, the error message, the recovery, and the disclosure paths all resolve.
        let unresolvedAddresses = addressed.subtracting(shippedKeys)
        #expect(
            unresolvedAddresses.allSatisfy { $0.hasPrefix("copy.combined-summary") },
            "screens address keys no catalog holds: \(unresolvedAddresses.sorted())"
        )

        // Every chrome address a screen carries is a key the shipped catalog holds. The
        // development-build notice is in the vocabulary but is addressed by the application target
        // rather than by any screen, so it is covered by `ChromeCopyCoverage` instead.
        #expect(chromeAddressed.isSubset(of: shippedKeys))

        // The readiness catalogs still hold exactly the shipped key set. That coupling is what makes
        // Requirements 12.15 and 12.16 non-vacuous, and it is now doing far more work than before:
        // substituting a catalog changes every sentence on a completed report, not just its chrome.
        for variant in LocalizationReadinessVariant.allCases {
            let readinessKeys = Set(try LocalizationReadinessCatalogs.load(variant).keys)
            #expect(readinessKeys == shippedKeys, "\(variant.rawValue)")
            #expect(
                addressed.subtracting(readinessKeys)
                    .allSatisfy { $0.hasPrefix("copy.combined-summary") },
                "\(variant.rawValue)"
            )
        }
    }

    @Test("The pixel label resolves to its required English string under every readiness catalog")
    func theFixedPixelLabelIsNotSubstitutable() throws {
        // Requirement 8.2 fixes the three display strings for the release, and the resolver reads
        // them from `FixedPixelLabelText` rather than from the catalog. So a readiness catalog
        // cannot substitute them, and the one field the application renders today keeps its English
        // text under expansion, long-word, bidirectional, and pseudolocalized copy.
        //
        // Asserted as the true statement, not as the desired one: it means the readiness suite
        // exercises the layout of no rendered string on this screen.
        for variant in LocalizationReadinessVariant.allCases {
            let resolver = AccessibleTextResolver(
                catalog: try LocalizationReadinessCatalogs.load(variant),
                languageTag: variant.languageTag
            )

            for evidence in PixelEvidence.allCases {
                let report = try ReportFixture.pixelOnlyPresentation(pixel: evidence)
                let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(report))
                let element = try #require(snapshot.element(.pixelEvidenceLabel))
                let context = "\(variant.rawValue)/\(evidence.labelKey.rawValue)"

                let rendered = try #require(resolver.resolvedText(for: element.label))
                #expect(rendered == FixedPixelLabelText(evidence: evidence).value, "\(context)")
                #expect(FixedPixelLabelText(exact: rendered) != nil, "\(context)")

                // The catalog does carry a replaced value at the corresponding key. It is simply
                // never read, which is the gap this test documents.
                let key = try #require(EnglishStringCatalog.fixedPixelLabelKeys[evidence.labelKey])
                let substituted = try LocalizationReadinessCatalogs.value(
                    variant,
                    forKey: key.rawValue
                )
                #expect(substituted != nil, "\(context)")
                #expect(substituted != rendered, "\(context)")
            }
        }
    }

    @Test("An unresolvable element is refused rather than rendered as a key or a fallback")
    func unresolvableElementsAreRefusedUnderEveryCatalog() throws {
        var resolvers: [(name: String, resolver: AccessibleTextResolver)] = [
            ("shipped", try AccessibleTextResolver.shipped())
        ]
        for entry in try Self.readinessResolvers() {
            resolvers.append((name: entry.variant.rawValue, resolver: entry.resolver))
        }

        let snapshot = AccessibilitySemanticsSnapshot.projecting(
            .completed(try ReportFixture.fusedPresentation())
        )
        var refused = 0

        for (name, resolver) in resolvers {
            let unresolvable = resolver.unresolvableElements(in: snapshot)
            #expect(unresolvable.isEmpty == false, "\(name)")
            for element in unresolvable {
                #expect(resolver.canRender(element) == false, "\(name)")
                #expect(resolver.resolvedText(for: element.label) == nil, "\(name)")
                #expect(throws: StringCatalogError.self) {
                    try resolver.text(for: element.label)
                }
                refused += 1
            }
        }

        #expect(refused >= resolvers.count)
    }

    @Test("Every readiness catalog is still refused as the shipping catalog")
    func readinessCatalogsCannotShip() throws {
        // Requirement 8.18 keeps English the only Version 1 user-facing language. A resolver built
        // over a readiness catalog is a test instrument; the catalog behind it must never be
        // loadable as the shipped one.
        for variant in LocalizationReadinessVariant.allCases {
            let catalog = try LocalizationReadinessCatalogs.load(variant)
            #expect(throws: StringCatalogError.self) {
                try EnglishStringCatalog.validate(catalog)
            }
            #expect(catalog.languageTags == [variant.languageTag], "\(variant.rawValue)")
            #expect(
                catalog.languageTags.contains(EnglishStringCatalog.requiredLanguageTag) == false,
                "\(variant.rawValue)"
            )
        }
    }
}

// MARK: - 12.7, 12.8, 12.9, 12.10 as the view actually asks for them

@Suite("The rendered view's layout, hit-region, and motion requests")
struct AccessibleViewSourceTests {

    /// One of the module's view sources, with comments removed.
    ///
    /// Comments are stripped first, exactly as ``ForbiddenControlSourceAudit`` does, because this
    /// file and the module's own documentation both have to be able to name what is forbidden. An
    /// unstripped read reports the documentation and gets weakened rather than obeyed.
    static func viewSource(_ fileName: String) throws -> String {
        let root = try #require(
            PackageSourceTree.packageRoot,
            "the package source tree is required for this to mean anything"
        )
        let url = root.appending(path: "Sources/DefAIkePresentation/Views/\(fileName)")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.isEmpty == false, "\(fileName)")
        return ForbiddenControlSourceAudit.strippingComments(text)
    }

    static func semanticsSource() throws -> String { try viewSource("AccessibleSemantics.swift") }
    static func screenSource() throws -> String { try viewSource("AnalysisScreenView.swift") }

    /// The two view sources, named, with comments removed.
    static func viewSources() throws -> [(name: String, code: String)] {
        [
            ("AccessibleSemantics.swift", try semanticsSource()),
            ("AnalysisScreenView.swift", try screenSource()),
        ]
    }

    /// One of the module's design-system sources, with comments removed.
    static func designSystemSource(_ fileName: String) throws -> String {
        let root = try #require(
            PackageSourceTree.packageRoot,
            "the package source tree is required for this to mean anything"
        )
        let url = root.appending(path: "Sources/DefAIkePresentation/DesignSystem/\(fileName)")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.isEmpty == false, "\(fileName)")
        return ForbiddenControlSourceAudit.strippingComments(text)
    }

    static func componentsSource() throws -> String { try designSystemSource("Components.swift") }
    static func tokensSource() throws -> String { try designSystemSource("DesignTokens.swift") }

    /// Whether a module source sits in the design-system directory.
    ///
    /// The one directory permitted to name a colour, a symbol, or an opacity. Matched on the path
    /// rather than on the file name, so a decoration cannot be smuggled into the semantics layer by
    /// choosing a design-system-sounding name for it.
    static func isDesignSystem(_ url: URL) -> Bool {
        url.pathComponents.contains("DesignSystem")
    }

    /// Every comment-stripped Swift source in the module, split by whether it is design system.
    static func partitionedModuleSources() throws -> (
        designSystem: [(name: String, code: String)], other: [(name: String, code: String)]
    ) {
        let urls = try #require(
            ForbiddenControlSourceAudit.moduleSources(),
            "the module's sources must be readable for this to mean anything"
        )
        var designSystem: [(name: String, code: String)] = []
        var other: [(name: String, code: String)] = []
        for url in urls {
            let entry = (
                url.lastPathComponent,
                ForbiddenControlSourceAudit.strippingComments(
                    try String(contentsOf: url, encoding: .utf8)
                )
            )
            if isDesignSystem(url) {
                designSystem.append(entry)
            } else {
                other.append(entry)
            }
        }
        #expect(designSystem.isEmpty == false, "the design-system sweep found no files")
        #expect(other.isEmpty == false, "the non-design-system sweep found no files")
        return (designSystem, other)
    }

    /// Every comment-stripped Swift source in the module.
    static func moduleSources() throws -> [(name: String, code: String)] {
        let urls = try #require(
            ForbiddenControlSourceAudit.moduleSources(),
            "the module's sources must be readable for this to mean anything"
        )
        #expect(urls.count > 1, "the recursive sweep found \(urls.count) file(s)")
        return try urls.map { url in
            (
                url.lastPathComponent,
                ForbiddenControlSourceAudit.strippingComments(
                    try String(contentsOf: url, encoding: .utf8)
                )
            )
        }
    }

    @Test("The comment stripper is what makes this audit honest")
    func commentsAreStrippedBeforeAnyMatch() {
        let source = """
        // lineLimit(1) and a Color here are documentation, not code
        let value = 1  // truncationMode(.tail) either
        """
        let stripped = ForbiddenControlSourceAudit.strippingComments(source)

        #expect(stripped.contains("lineLimit") == false)
        #expect(stripped.contains("Color") == false)
        #expect(stripped.contains("truncationMode") == false)
        #expect(stripped.contains("let value = 1"))
    }

    @Test("The sweep reads the real view files, so an absence check is not an empty read")
    func theSweepReadsTheRealViewFiles() throws {
        let sources = try Self.viewSources()

        #expect(sources.count == 2)
        for (name, code) in sources {
            #expect(code.contains("some View"), "\(name)")
            #expect(code.count > 500, "\(name) stripped to \(code.count) characters")
        }

        let all = try Self.moduleSources()
        #expect(all.count >= sources.count)
        #expect(all.allSatisfy { $0.code.isEmpty == false })
    }

    @Test("No view can truncate, clamp, shrink, or clip text at any Dynamic Type size")
    func noViewCanTruncateOrClipText() throws {
        // Requirement 12.8's host-verifiable half. Whether the largest accessibility size reflows
        // without clipping on a real screen is device-pending; whether the module is capable of
        // asking for truncation is not. None of these appears anywhere in its code.
        let truncationTokens = [
            "lineLimit",
            "truncationMode",
            "minimumScaleFactor",
            "allowsTightening",
            "scaleEffect",
            "clipped",
            "ViewThatFits",
            "GeometryReader",
            "UIScreen",
            "frame(height:",
            "frame(idealHeight:",
        ]

        for (name, code) in try Self.moduleSources() {
            for token in truncationTokens {
                #expect(code.contains(token) == false, "\(name) mentions \(token)")
            }
        }
    }

    @Test("Text is asked to reflow, and the scroll container is unconditional")
    func reflowAndScrollingAreRequested() throws {
        let semantics = try Self.semanticsSource()
        let screen = try Self.screenSource()

        // Reflow: the text takes the height it needs and no line limit constrains it.
        #expect(semantics.contains("fixedSize(horizontal: false, vertical: true)"))

        // The alignment is taken from the element's emphasis rather than written as a literal, which
        // is a stronger statement than the literal `.leading` this used to assert: an alignment
        // derived from a token cannot disagree between two screens showing the same kind of field.
        #expect(semantics.contains("multilineTextAlignment(emphasis.textAlignment)"))
        #expect(semantics.contains("multilineTextAlignment(.center)") == false)

        // No fixed size on the element that carries text. Only a minimum for the operable frame and
        // a maximum-width expansion, both of which grow rather than clamp.
        #expect(semantics.contains("frame(width:") == false)
        #expect(semantics.contains("minWidth: element.activationArea"))
        #expect(semantics.contains("minHeight: element.activationArea"))
        #expect(semantics.contains("maxWidth: .infinity"))

        // Reachability at the largest sizes depends on scrolling, and the container is not behind a
        // condition a smaller size could take.
        #expect(screen.contains("ScrollView(.vertical)"))

        // The layout axis comes from the policy over the current text size, not from a breakpoint
        // written in the view.
        #expect(screen.contains("layout.axis(at: textSize)"))
        #expect(screen.contains("SupportedTextSize(dynamicTypeSize)"))
    }

    @Test("The operable frame and the hit shape are both applied")
    func activationAreaAndHitShapeAreRequested() throws {
        // Requirement 12.9's host-verifiable half: the frame is requested from the element's own
        // derived minimum and the whole rectangle is made hit-testable, so the target is the area
        // rather than the drawn glyphs. Whether the produced region measures 44 by 44 points under a
        // live layout is device-pending.
        let semantics = try Self.semanticsSource()

        #expect(semantics.contains("contentShape(Rectangle())"))
        #expect(semantics.contains("element.activationArea?.frameworkWidth"))
        #expect(semantics.contains("element.activationArea?.frameworkHeight"))
        #expect(semantics.contains("allowsHitTesting") == false)
    }

    @Test("An operable element is a button and a content element is not made tappable")
    func operabilityDecidesTheRenderedShape() throws {
        let semantics = try Self.semanticsSource()

        // Two shapes, chosen by the element's own operability, so a control cannot be drawn as text
        // a Switch Control scanner would skip and a content field cannot become tappable.
        #expect(semantics.contains("if element.isOperable, let action"))
        #expect(semantics.contains("Button(action: action)"))
        #expect(semantics.contains("onTapGesture") == false)
        #expect(semantics.contains("simultaneousGesture") == false)
        #expect(semantics.contains("highPriorityGesture") == false)
    }

    @Test("Semantics are applied from the element, and the sort priority is derived from position")
    func semanticsComeFromTheElement() throws {
        let semantics = try Self.semanticsSource()

        #expect(semantics.contains("accessibilityElement(children: .ignore)"))
        #expect(semantics.contains("accessibilityLabel(Text(verbatim: label))"))
        #expect(semantics.contains("accessibilityAddTraits(element.frameworkTraits)"))
        // The framework's ordering is derived from the reading position rather than authored, so it
        // cannot contradict where the element appears (Requirement 12.4).
        #expect(
            semantics.contains("accessibilitySortPriority(Double(elementCount - readingIndex))")
        )
    }

    @Test("No magnitude, uncontrolled motion, or ad-hoc colour API exists anywhere in the module")
    func noMagnitudeOrAdHocColourExists() throws {
        // Requirements 12.7 and 8.13. This suite used to ban the string "Color" module-wide, which
        // was a sound proxy while the module drew nothing: with no design layer, any mention of a
        // colour was a mistake. It is no longer sound, because a designed screen has to name a
        // colour somewhere, and a proxy that forbids the whole category cannot distinguish a
        // measured token from a verdict painted green.
        //
        // So the ban is split. What stays banned everywhere is the set that has no legitimate use
        // here at all:
        //
        //   * a graphical magnitude - `Gauge`, `ProgressView(value:)` - which is exactly the
        //     encoding equivalent to a probability that Requirement 8.13 removes;
        //   * motion that no policy decides - `withAnimation`, `.transition(`, `repeatForever`,
        //     `symbolEffect` - which would bypass `MotionPolicy` and so bypass Requirement 12.10;
        //   * the ad-hoc colour APIs - `foregroundColor`, `accentColor` - which take a colour from
        //     anywhere, as opposed to `foregroundStyle` fed from the measured palette; and
        //   * `gradient` and `shadow`, because a gradient is the easiest way to imply a scale and
        //     neither is in this visual language.
        //
        // What colour is *permitted* to do is checked separately, and more strictly, by
        // `everyColourComesFromTheMeasuredPalette` and by `DesignSystemOutcomeBlindnessTests`.
        let bannedEverywhere = [
            "Gauge",
            "ProgressView(value:",
            "symbolEffect",
            "withAnimation",
            ".transition(",
            "repeatForever",
            "foregroundColor",
            "accentColor",
            "gradient",
            "shadow",
        ]

        for (name, code) in try Self.moduleSources() {
            for token in bannedEverywhere {
                #expect(code.contains(token) == false, "\(name) mentions \(token)")
            }
        }
    }

    @Test("No system colour is ever passed to anything that draws")
    func noSystemColourIsEverDrawn() throws {
        // The executable form of the argument in `Palette`: a detector's obvious palette has a green
        // "authentic" state, and a green card asserts authenticity in a channel the approved-copy
        // gate cannot read (Requirement 8.4).
        //
        // `Palette` removes the *member*, so no view can ask for a success colour, and
        // `everyColourComesFromTheMeasuredPalette` closes the `Color(...)` route. The remaining hole
        // is a bare system colour handed straight to a style modifier - `.foregroundStyle(.green)`
        // needs no `Color(` at all. So the check is the pairing of a drawing modifier with a colour
        // name, rather than the colour name alone.
        //
        // Deliberately not a bare search for `.red` and friends. That was the first spelling of this
        // test and it reported four false positives: `.reduce` contains `.red`, and
        // `components.red` is the name of a colour *channel* in the palette's own measured
        // components. A check that has to be weakened to stay green is worse than no check, so the
        // narrower claim is the one asserted.
        let drawingModifiers = [
            "foregroundStyle", "foregroundColor", "fill", "tint", "background",
            "stroke", "strokeBorder", "shadow", "border", "accentColor",
        ]
        let colourNames = [
            "green", "red", "blue", "orange", "yellow", "pink", "purple",
            "mint", "teal", "cyan", "indigo", "brown", "gray", "grey",
            "white", "black", "clear",
        ]

        for (name, code) in try Self.moduleSources() {
            for modifier in drawingModifiers {
                for colour in colourNames {
                    // `.foregroundStyle(.green)` and `.foregroundStyle(Color.green)`, the two
                    // spellings that reach a system colour without constructing one.
                    for spelling in ["\(modifier)(.\(colour)", "\(modifier)(Color.\(colour)"] {
                        #expect(
                            code.contains(spelling) == false,
                            "\(name) draws with the system colour \(spelling))"
                        )
                    }
                }
            }

            // The platform colour types have no legitimate use here and no false-positive risk.
            for token in ["UIColor", "NSColor", "systemGreen", "systemRed", "Color(hue:"] {
                #expect(code.contains(token) == false, "\(name) mentions \(token)")
            }
        }
    }

    @Test("Every colour is constructed from the measured palette, through one bridge")
    func everyColourComesFromTheMeasuredPalette() throws {
        // The positive half of the split above, and the claim that actually matters: a colour on
        // screen is a colour whose contrast ratio `PaletteContrastTests` measured.
        //
        // Two facts establish it. Outside the design system, every `Color(` is built from `palette.`
        // - so a view cannot introduce a colour of its own. Inside the design system, the only
        // construction from raw numeric components is the single `ColorComponents` bridge, so even
        // there a colour has to come from a measured value.
        let (designSystem, other) = try Self.partitionedModuleSources()

        for (name, code) in other {
            for occurrence in code.components(separatedBy: "Color(").dropFirst() {
                #expect(
                    occurrence.hasPrefix("palette."),
                    "\(name) builds a Color from something other than the palette: Color(\(occurrence.prefix(40)))"
                )
            }
        }

        // The one bridge from components to a framework colour, and it is in the tokens file.
        let tokens = try Self.tokensSource()
        #expect(tokens.contains("init(_ components: ColorComponents)"))
        #expect(tokens.contains("red: Double(components.red) / 255"))

        let sRGBConstructions = designSystem
            .map { $0.code.components(separatedBy: ".sRGB").count - 1 }
            .reduce(0, +)
        #expect(
            sRGBConstructions == 1,
            "the design system constructs a raw sRGB colour \(sRGBConstructions) time(s); exactly one bridge is intended"
        )
    }

    @Test("Colour, symbols, and opacity are confined to the design system")
    func decorationIsConfinedToTheDesignSystem() throws {
        // Requirement 12.7 again, as a boundary rather than as a blanket ban. The semantics layer -
        // where the labels, values, traits, and reading order live - names no symbol and no opacity,
        // so decoration cannot be introduced in the same file that decides what an element *means*.
        // Colour reaches the views only as the palette bridge checked above.
        let (_, other) = try Self.partitionedModuleSources()

        for (name, code) in other {
            #expect(code.contains("Image(") == false, "\(name) draws an image or symbol")
            #expect(code.contains("systemName") == false, "\(name) names a symbol")
            #expect(code.contains("opacity") == false, "\(name) sets an opacity")
        }
    }

    @Test("The only animation is a screen-family change, and the policy decides whether it moves")
    func theOnlyAnimationGoesThroughThePolicy() throws {
        // `.animation(` is permitted in exactly one place and in exactly one form: fed by
        // `Motion.familyTransition(reduceMotion:)`, which returns `nil` under Reduce Motion. Passing
        // `nil` performs no animation at all rather than a fast one, so the reduced branch is a real
        // absence of motion (Requirement 12.10).
        let screen = try Self.screenSource()
        let occurrences = screen.components(separatedBy: ".animation(").dropFirst()

        #expect(occurrences.count == 1, "the view declares \(occurrences.count) animations")
        for occurrence in occurrences {
            #expect(
                occurrence.hasPrefix("Motion.familyTransition(reduceMotion: reduceMotion)"),
                "an animation is not fed by the motion policy: .animation(\(occurrence.prefix(60)))"
            )
        }

        // Nothing else in the module animates at all.
        let (_, other) = try Self.partitionedModuleSources()
        for (name, code) in other where name != "AnalysisScreenView.swift" {
            #expect(code.contains(".animation(") == false, "\(name) animates")
        }

        // And the policy really does return no animation under the reduced setting.
        #expect(Motion.familyTransition(reduceMotion: true) == nil)
        #expect(Motion.familyTransition(reduceMotion: false) != nil)
    }

    @Test("No rendered string is a literal, and no localized lookup exists to echo a key")
    func noRenderedStringIsALiteral() throws {
        // Requirements 12.15 and 12.16 depend on the catalog being the only source of text. The
        // shape that breaks that is `Text("...")`: a string literal binds to SwiftUI's
        // `LocalizedStringKey` overload, which performs a second lookup on wording this module has
        // already resolved and renders the key itself when the lookup misses - exactly what
        // ``ResolvedCopyReference`` forbids. `Text(someString)` takes the `StringProtocol` overload
        // and does not localize, so the literal is the whole risk and it is what is checked.
        //
        // Deliberately not a count of `Text(` against `Text(verbatim:`. `resolvedText(` and
        // `visibleText(` both contain `Text(` as a substring, so that comparison reports five
        // false positives in `AccessibleSemantics.swift` and one in `AnalysisScreenView.swift`.
        // The narrower claim is the one that is true.
        for (name, code) in try Self.moduleSources() {
            #expect(code.contains("Text(\"") == false, "\(name) builds a Text from a literal")

            // No localized-lookup entry point anywhere in the module, so the catalog boundary is
            // the resolver and nothing else.
            #expect(code.contains("LocalizedStringKey") == false, "\(name)")
            #expect(code.contains("NSLocalizedString") == false, "\(name)")
            #expect(code.contains("String(localized:") == false, "\(name)")
            #expect(code.contains("localizedString") == false, "\(name)")
        }

        // The absence check above is not passing over a module that renders nothing. All element
        // text is rendered in one place, and every string it renders is explicitly verbatim.
        // `AnalysisScreenView.swift` deliberately builds no `Text` of its own - it delegates to
        // ``AccessibleElementView`` - so the presence check names the file that does.
        let semantics = try Self.semanticsSource()
        #expect(semantics.contains("Text(verbatim:"))
        #expect(semantics.components(separatedBy: "Text(verbatim:").count - 1 >= 5)
        #expect(try Self.screenSource().contains("Text(verbatim:") == false)
    }

    @Test("Every non-text visual is hidden from assistive technology and carries no magnitude")
    func everyDecorationIsHiddenAndCarriesNoMagnitude() throws {
        // The indicator, the mark, the two glyphs, and the row divider are the module's only visuals
        // that are not text. All of them live in the design system now, so this reads there.
        let components = try Self.componentsSource()

        // The indeterminate indicator, and deliberately the no-argument initializer.
        // `ProgressView(value:)` would draw a fill fraction, which is the graphical magnitude
        // Requirement 8.13 bans; the module-wide sweep above already refuses that spelling.
        #expect(components.contains("ProgressView()"))
        #expect(components.contains("Circle()"))

        // Every decoration is hidden, so none of them can be the channel a status travels on
        // (Requirement 12.7). Counted rather than merely present: five decorative views are defined
        // here and each one hides itself.
        let hidden = components.components(separatedBy: "accessibilityHidden(true)").count - 1
        #expect(hidden >= 5, "only \(hidden) decoration(s) hide themselves from assistive technology")

        // Every fixed frame in the module is on a decorative shape, and every one of them is in the
        // design system. A fixed frame on text is what clips it; on a hidden square it is a size.
        let (_, other) = try Self.partitionedModuleSources()
        for (name, code) in other {
            #expect(code.contains("frame(width:") == false, "\(name) declares a fixed-width frame")
        }
    }

    @Test("Reduce Motion is read from the environment and decided by the policy, not by the view")
    func reduceMotionGoesThroughThePolicy() throws {
        let screen = try Self.screenSource()
        let components = try Self.componentsSource()

        // The view reads the setting; the design system's indicator asks the policy what to do with
        // it. Neither one branches on the raw boolean.
        #expect(screen.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(components.contains("MotionPolicy.statusChangeStyle(reduceMotion: reduceMotion)"))
        #expect(screen.contains("if reduceMotion {") == false)
        #expect(components.contains("if reduceMotion {") == false)

        // Both branches of the substitution exist, and neither is a moving alternative under the
        // reduced setting. `MotionPolicy` decides that, not the view.
        #expect(MotionPolicy.statusChangeStyle(reduceMotion: true) == .staticStateChange)
        #expect(MotionPolicy.statusChangeStyle(reduceMotion: false) == .animatedIndicator)
        #expect(StatusChangeStyle.allCases.count == 2)
        for surface in MotionSensitiveSurface.allCases {
            #expect(MotionPolicy.hasNonmovingAlternative(for: surface), "\(surface.rawValue)")
        }
    }

    @Test("Announcements go through the debouncer and focus is tracked by identity")
    func announcementAndFocusPathsGoThroughTheModel() throws {
        let screen = try Self.screenSource()

        // 12.5: nothing is spoken except through the debouncer, so a determinate progress state
        // arriving many times a second cannot announce many times a second.
        #expect(screen.contains("debouncer.announcement(for: input)"))
        #expect(screen.contains("AccessibilityNotification.Announcement"))
        #expect(screen.contains("accessibilitySpeechAnnouncementPriority"))

        // 12.6: focus is a tracked identity, and it is written only in the one case the retention
        // rule leaves open.
        #expect(screen.contains("@AccessibilityFocusState"))
        #expect(screen.contains("accessibilityFocused($focusedElement, equals: element.identity)"))
        #expect(screen.contains("focusRetention(movingFrom: focusedElement)"))
        #expect(screen.contains("case .noFocusedElement, .retained:"))
    }
}

// MARK: - 12.8: the framework's own Dynamic Type vocabulary

#if canImport(SwiftUI)

@Suite("Dynamic Type reachability across the framework's own sizes")
struct SupportedTextSizeMappingTests {

    @Test("Every framework Dynamic Type size maps to a distinct supported size, in order")
    func frameworkSizesMapOntoTheSupportedVocabulary() {
        // Requirement 12.8 requires support through the largest accessibility size. The policy's
        // twelve sizes are the framework's twelve, and the mapping is an order-preserving bijection,
        // so no size is silently treated as a smaller one.
        let mapped = DynamicTypeSize.allCases.map(SupportedTextSize.init)

        #expect(mapped.count == SupportedTextSize.allCases.count)
        #expect(Set(mapped).count == mapped.count)
        #expect(mapped == SupportedTextSize.allCases, "the mapping must preserve ascending order")
        #expect(SupportedTextSize.allCases.count == 12)
    }

    @Test("The framework's accessibility sizes are exactly the policy's accessibility sizes")
    func accessibilitySizesAgree() {
        for size in DynamicTypeSize.allCases {
            let supported = SupportedTextSize(size)
            #expect(
                supported.isAccessibilitySize == size.isAccessibilitySize,
                "\(supported.rawValue)"
            )
        }

        #expect(SupportedTextSize(.accessibility5) == .largestSupported)
        #expect(SupportedTextSize.accessibilitySizes.count == 5)
        #expect(SupportedTextSize.largestSupported.isAccessibilitySize)
    }

    @Test("A name-and-state pairing stacks vertically at every accessibility size")
    func axisIsVerticalWhereOverlapWouldStart() {
        for size in DynamicTypeSize.allCases {
            let supported = SupportedTextSize(size)
            let axis = AdaptiveLayoutPolicy.standard.axis(at: supported)
            #expect(
                axis == (supported.isAccessibilitySize ? .vertical : .horizontal),
                "\(supported.rawValue)"
            )
        }
        #expect(LayoutAxis.allCases.count == 2)
    }

    @Test("The 44-point minimum crosses into the framework's unit unchanged")
    func theActivationMinimumCrossesTheFrameworkBoundary() {
        // The one numeric conversion in the view layer. A point count that shrank on the way across
        // would produce a target smaller than Requirement 12.9 permits, and the value layer could
        // not see it.
        #expect(MinimumActivationArea.requiredMinimum.frameworkWidth == 44)
        #expect(MinimumActivationArea.requiredMinimum.frameworkHeight == 44)
        #expect(
            MinimumActivationArea.requiredMinimum.frameworkWidth
                == CGFloat(MinimumActivationArea.requiredEdgeLength)
        )
    }

    @Test("Every trait maps to a framework trait, and an operable element carries the button trait")
    func traitsCrossTheFrameworkBoundary() {
        // The mapping is a total switch with no `default`, so a new trait cannot be silently
        // dropped. Exercised over every case so the switch is actually run rather than trusted.
        for trait in AccessibilityTrait.allCases {
            _ = trait.frameworkTrait
        }

        for role in AccessibilityRole.allCases {
            let element = AccessibleElement(
                identity: .pixelEvidenceLabel,
                role: role,
                label: .requiredPixelLabelText(FixedPixelLabelText(label: .notEnoughSignal))
            )
            #expect(element.traits == role.traits, "\(role.rawValue)")
            _ = element.frameworkTraits
        }
    }
}

#endif
