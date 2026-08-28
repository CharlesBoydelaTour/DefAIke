import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkePresentation

// What the design layer is allowed to do, asserted rather than described.
//
// The visual layer introduces the one thing this codebase had previously removed entirely: a colour.
// Removing it was a real guarantee, because the approved-copy gate reads sentences and cannot read a
// fill, so a claim made in colour passes every other check the application has. Adding a design
// layer back therefore has to come with the checks that make the guarantee hold by construction
// rather than by intention.
//
// Four suites, in order of how much they matter:
//
//   1. ``DesignSystemOutcomeBlindnessTests`` - the three verdicts are visually identical, and the
//      two evidence lanes are visually identical. This is the one that would catch a green card.
//   2. ``PaletteContrastTests`` - every pair on screen meets its WCAG threshold, computed from the
//      palette's own components rather than inspected by eye.
//   3. ``PaletteVocabularyTests`` - there is no member a success colour could live in.
//   4. ``ScreenCompositionOrderTests`` - grouping elements into regions did not reorder them, so the
//      reading and action order Requirement 12.4 fixes is unchanged.

// MARK: - 1. Colour can never encode an outcome

@Suite("The design layer is blind to every outcome")
struct DesignSystemOutcomeBlindnessTests {

    /// The three fixed pixel labels, as evidence values.
    static let everyPixelEvidence: [PixelEvidence] = [
        .signalsConsistentWithAIGeneration,
        .noStrongSignalDetected,
        .notEnoughSignal,
    ]

    @Test("All three pixel labels produce an identical set of emphases and colours")
    func theThreeVerdictsAreVisuallyIndistinguishable() throws {
        // The claim: swapping the verdict changes the words and nothing else. If a future edit made
        // the positive label bolder, larger, or differently coloured, this fails.
        var treatments: Set<[String]> = []

        for evidence in Self.everyPixelEvidence {
            let presentation = try ReportFixture.pixelOnlyPresentation(pixel: evidence)
            let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(presentation))

            // Every element's identity, emphasis, region, and both resolved colours, in reading
            // order. Rendered as strings so the comparison covers the actual drawn values.
            let treatment = snapshot.elements.map { element -> String in
                let emphasis = VisualEmphasis.emphasis(for: element.identity)
                let region = ScreenRegion.region(for: element.identity)
                let foreground = Palette.light.foreground(for: emphasis)
                let background = Palette.light.background(for: region.surface, region: region)
                return [
                    element.identity.stableKey,
                    emphasis.rawValue,
                    region.rawValue,
                    "\(foreground)",
                    "\(String(describing: background))",
                ].joined(separator: "|")
            }
            treatments.insert(treatment)
        }

        #expect(
            treatments.count == 1,
            "the three pixel labels produce \(treatments.count) distinct visual treatments; they must produce one"
        )
    }

    @Test("The emphasis function cannot be shown an outcome")
    func emphasisIsDerivedFromIdentityAlone() {
        // A structural restatement of the above. `emphasis(for:)` takes an identity, and the whole
        // identity vocabulary is enumerable, so the set of reachable emphases is fixed and finite -
        // it cannot vary with a verdict, a lane state, a fusion result, or a byte status, because
        // none of those is an input.
        let reachable = Set(AccessibleElementIdentity.allIdentities.map(VisualEmphasis.emphasis))

        #expect(reachable.isEmpty == false)
        // Every emphasis the vocabulary defines is actually used by some element, so no case is dead
        // and no element falls through to a default. `emphasis(for:)` has no `default`.
        #expect(reachable == Set(VisualEmphasis.allCases))
    }

    @Test("Both evidence lanes resolve to the same emphasis, region, surface, and colours")
    func neitherLaneCanBeRankedAboveTheOther() {
        // Requirements 7.1 and 7.8: neither lane may suppress, override, or rank the other. The two
        // lanes share their emphasis cases and their region case, so a visual ranking is not
        // something the views avoid - it is not expressible.
        let pixelHeadline = VisualEmphasis.emphasis(for: .pixelEvidenceLabel)
        let provenanceHeadline = VisualEmphasis.emphasis(for: .provenanceLaneState)
        #expect(pixelHeadline == provenanceHeadline)
        #expect(pixelHeadline == .laneHeadline)

        let pixelBody = VisualEmphasis.emphasis(for: .pixelEvidenceExplanation)
        let provenanceBody = VisualEmphasis.emphasis(for: .screenshotProvenanceExplanation)
        #expect(pixelBody == provenanceBody)
        #expect(pixelBody == .laneBody)

        // The lane emphases are exactly the two the type advertises.
        #expect(VisualEmphasis.laneEmphases == [pixelHeadline, pixelBody])

        // One region case, so one surface and one set of colours.
        for identity in [
            AccessibleElementIdentity.pixelEvidenceLabel, .pixelEvidenceExplanation,
            .provenanceLaneState, .screenshotProvenanceExplanation,
        ] {
            #expect(ScreenRegion.region(for: identity) == .evidenceLane)
        }
        #expect(ScreenRegion.evidenceLane.surface == .card)

        for appearance in Appearance.allCases {
            let palette = Palette.resolved(for: appearance)
            #expect(
                palette.foreground(for: pixelHeadline) == palette.foreground(for: provenanceHeadline),
                "\(appearance.rawValue)"
            )
            #expect(
                palette.foreground(for: pixelBody) == palette.foreground(for: provenanceBody),
                "\(appearance.rawValue)"
            )
        }
    }

    @Test("A completed screen draws two lane regions, and they are interchangeable")
    func theTwoLaneRegionsAreDrawnIdentically() throws {
        // The composition splits the run of lane elements at the second headline, so a report with
        // both lanes produces two separate cards rather than one merged block - and the two carry
        // the same region case, so they cannot be styled apart.
        let presentation = try ReportFixture.pixelOnlyPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(presentation))
        let laneRegions = ScreenComposition.regions(of: snapshot).filter { $0.region == .evidenceLane }

        #expect(laneRegions.count == 2, "a completed report drew \(laneRegions.count) lane region(s)")
        #expect(Set(laneRegions.map(\.surface)).count == 1)
        #expect(Set(laneRegions.map(\.region)).count == 1)

        // Each lane begins with a headline, which is what makes them separable at all.
        for lane in laneRegions {
            let first = try #require(lane.elements.first)
            #expect(ScreenComposition.isLaneHeadline(first.identity), "\(first.identity.stableKey)")
        }
    }
}

// MARK: - 2. The contrast ratios, computed

@Suite("Palette contrast, computed from the palette's own components")
struct PaletteContrastTests {

    @Test("The relative-luminance formula is right, checked against known values")
    func theFormulaIsCorrect() {
        // The ratios below are only worth anything if the arithmetic is. Three anchors from the WCAG
        // definition itself: black-on-white is exactly 21:1, a colour against itself is 1:1, and
        // mid-grey against white is a known value.
        let white = ColorComponents(0xFF, 0xFF, 0xFF)
        let black = ColorComponents(0x00, 0x00, 0x00)

        #expect(abs(white.relativeLuminance - 1.0) < 0.000_1)
        #expect(abs(black.relativeLuminance - 0.0) < 0.000_1)
        #expect(abs(white.contrastRatio(against: black) - 21.0) < 0.01)
        #expect(abs(white.contrastRatio(against: white) - 1.0) < 0.000_1)

        // Symmetric, so no caller can improve a ratio by swapping the arguments.
        #expect(white.contrastRatio(against: black) == black.contrastRatio(against: white))

        // A known reference point: #767676 on white is the canonical 4.54:1 "smallest passing grey".
        let referenceGrey = ColorComponents(0x76, 0x76, 0x76)
        #expect(abs(referenceGrey.contrastRatio(against: white) - 4.54) < 0.02)
    }

    @Test("Every text pair meets 4.5:1 in both appearances", arguments: Appearance.allCases)
    func textMeetsTheNormalTextThreshold(appearance: Appearance) {
        let palette = Palette.resolved(for: appearance)
        #expect(palette.textPairs.isEmpty == false)

        for pair in palette.textPairs {
            let ratio = pair.foreground.contrastRatio(against: pair.background)
            #expect(
                ratio >= Palette.textContrastMinimum,
                "\(appearance.rawValue): \(pair.name) is \(String(format: "%.2f", ratio)):1, below 4.5:1"
            )
        }
    }

    @Test("Every non-text boundary meets 3:1 in both appearances", arguments: Appearance.allCases)
    func nonTextMeetsTheBoundaryThreshold(appearance: Appearance) {
        let palette = Palette.resolved(for: appearance)
        #expect(palette.nonTextPairs.isEmpty == false)

        for pair in palette.nonTextPairs {
            let ratio = pair.foreground.contrastRatio(against: pair.background)
            #expect(
                ratio >= Palette.nonTextContrastMinimum,
                "\(appearance.rawValue): \(pair.name) is \(String(format: "%.2f", ratio)):1, below 3:1"
            )
        }
    }

    @Test("Every emphasis resolves to a foreground that passes on the surface it is drawn on")
    func everyEmphasisIsLegibleWhereItAppears() {
        // The pair lists above are named surfaces. This closes the loop from the other direction:
        // for every emphasis the module can produce, the colour it resolves to passes against the
        // background of the region its elements actually sit in.
        for appearance in Appearance.allCases {
            let palette = Palette.resolved(for: appearance)

            for identity in AccessibleElementIdentity.allIdentities {
                let emphasis = VisualEmphasis.emphasis(for: identity)
                let region = ScreenRegion.region(for: identity)
                let foreground = palette.foreground(for: emphasis)

                // The region's own fill, or the page when it draws none.
                let background =
                    palette.background(for: region.surface, region: region) ?? palette.background

                // The primary action is drawn on the accent fill rather than on the region's
                // background, and its own pair is already covered by `textPairs`.
                let effectiveBackground = emphasis.isOnFilledControl ? palette.accent : background
                let ratio = foreground.contrastRatio(against: effectiveBackground)

                #expect(
                    ratio >= Palette.textContrastMinimum,
                    """
                    \(appearance.rawValue): \(identity.stableKey) as \(emphasis.rawValue) in \
                    \(region.rawValue) is \(String(format: "%.2f", ratio)):1, below 4.5:1
                    """
                )
            }
        }
    }
}

// MARK: - 3. There is no success colour to reach for

@Suite("The palette has no member a success colour could occupy")
struct PaletteVocabularyTests {

    /// Names that would assert authenticity, safety, or a pass if they existed.
    ///
    /// The same technique ``ForbiddenControlAudit`` uses on the presentation models: walk the real
    /// stored properties rather than trusting a doc comment, so adding one later fails here.
    static let forbiddenNames = [
        "success", "positive", "verified", "authentic", "genuine", "safe", "pass",
        "clean", "trusted", "valid", "ok", "good", "green",
    ]

    @Test("No palette member is named for a positive outcome", arguments: Appearance.allCases)
    func noSuccessMemberExists(appearance: Appearance) {
        let mirror = Mirror(reflecting: Palette.resolved(for: appearance))
        #expect(mirror.children.isEmpty == false, "the reflection walk found no members")

        for child in mirror.children {
            let name = (child.label ?? "").lowercased()
            for forbidden in Self.forbiddenNames {
                #expect(
                    name.contains(forbidden) == false,
                    "Palette.\(name) could carry a \(forbidden) colour"
                )
            }
        }
    }

    @Test("The two tinted surfaces are the only ones, and neither names an outcome")
    func onlyCautionAndCriticalAreTinted() {
        // Colour is permitted to restate an approved sentence in exactly two places: the notice that
        // the lanes disagree, and the Analysis Error message. Both are reached through a region, and
        // no other region has a tinted surface.
        let tinted = ScreenRegion.allCases.filter { $0.surface == .inset }
        #expect(Set(tinted) == [.notice, .failure])

        // Neither of them is an evidence lane or a summary, so no verdict is ever tinted.
        #expect(tinted.contains(.evidenceLane) == false)
        #expect(tinted.contains(.summary) == false)

        // And the failure tint is reachable only from the failure region.
        for appearance in Appearance.allCases {
            let palette = Palette.resolved(for: appearance)
            #expect(palette.background(for: .inset, region: .failure) == palette.criticalSurface)
            #expect(palette.background(for: .inset, region: .notice) == palette.cautionSurface)
            #expect(palette.background(for: .card, region: .evidenceLane) == palette.surface)
        }
    }
}

// MARK: - 4. Grouping did not reorder anything

@Suite("Region grouping preserves the reading and action order exactly")
struct ScreenCompositionOrderTests {

    @Test("Concatenating the regions reproduces the snapshot's elements, for every family")
    func groupingPreservesOrderForEveryFamily() throws {
        // Requirement 12.4 makes the array order the reading order, and grouping is the operation
        // most likely to break it by accident. `regions(of:)` only ever cuts a contiguous run, so
        // this must hold exactly - element for element, not merely as a set.
        var familiesChecked: Set<AnalysisScreenFamily> = []

        for (family, input) in try AccessibilityLayerTests.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            let flattened = ScreenComposition.regions(of: snapshot).flatMap(\.elements)

            #expect(flattened == snapshot.elements, "\(family.rawValue) reordered its elements")
            #expect(
                flattened.map(\.identity) == snapshot.readingOrder,
                "\(family.rawValue) changed its reading order"
            )
            familiesChecked.insert(family)
        }

        // Not a vacuous pass over an empty fixture set.
        #expect(familiesChecked == Set(AnalysisScreenFamily.allCases))
    }

    @Test("The action order also survives grouping, for every family")
    func groupingPreservesTheActionOrder() throws {
        for (family, input) in try AccessibilityLayerTests.inputPerFamily() {
            let snapshot = AccessibilitySemanticsSnapshot.projecting(input)
            let grouped = ScreenComposition.regions(of: snapshot)
                .flatMap(\.elements)
                .filter(\.isOperable)
                .map(\.identity)

            #expect(grouped == snapshot.actionOrder, "\(family.rawValue) changed its action order")
        }
    }

    @Test("A completed report groups into regions without losing or duplicating an element")
    func aCompletedReportPartitionsExactly() throws {
        let presentation = try ReportFixture.pixelOnlyPresentation()
        let snapshot = AccessibilitySemanticsSnapshot.projecting(.completed(presentation))
        let regions = ScreenComposition.regions(of: snapshot)

        // A partition: every element appears exactly once, and the counts agree.
        let flattened = regions.flatMap(\.elements)
        #expect(flattened.count == snapshot.elements.count)
        #expect(Set(flattened.map(\.identity)).count == flattened.count, "an element was duplicated")
        #expect(regions.isEmpty == false)
        #expect(regions.allSatisfy { $0.elements.isEmpty == false }, "a region is empty")

        // Every element in a region really does belong to that region.
        for region in regions {
            for element in region.elements {
                #expect(
                    ScreenRegion.region(for: element.identity) == region.region,
                    "\(element.identity.stableKey) is grouped into \(region.region.rawValue)"
                )
            }
        }
    }

    @Test("Every region and surface is reachable, and every element has a region")
    func theRegionVocabularyIsTotalAndUsed() {
        // Total: `region(for:)` has no `default`, so this cannot trap. Used: every region case is
        // reached by some element, so no case is dead weight the grouping never produces.
        let reachable = Set(AccessibleElementIdentity.allIdentities.map(ScreenRegion.region))
        #expect(reachable == Set(ScreenRegion.allCases))

        // Every surface is used by some region, so no treatment is defined and never drawn.
        let surfaces = Set(ScreenRegion.allCases.map(\.surface))
        #expect(surfaces == Set(RegionSurface.allCases))
    }
}
