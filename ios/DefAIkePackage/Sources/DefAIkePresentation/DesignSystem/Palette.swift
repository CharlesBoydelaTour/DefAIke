// Foundation for `pow`, which the WCAG relative-luminance formula needs. Deliberately not behind
// `canImport(SwiftUI)`: the contrast arithmetic is the accessibility claim, and it has to be
// checkable on a host with no UI framework at all.
import Foundation

import DefAIkeDomain

// The colours, and the one colour this application does not have.
//
// # Why there is no success colour
//
// The obvious palette for a detector has a red state and a green state, and it is wrong here in a
// way no amount of care in the views would fix. "No strong signal detected" is not a finding of
// authenticity - Requirement 8.4 forbids presenting any result as proof of authenticity,
// authorship, intent, editing history, or the absence of localized editing - and a green card
// states precisely that conclusion. It states it in the one channel nothing reviews: the
// approved-copy gate reads sentences, so a claim smuggled in as a fill colour passes every check
// this application has.
//
// So there is no `success`, `positive`, `verified`, `authentic`, `safe`, or `pass` member below.
// Not a member left unused - no member at all, so no view can reach for one.
// `PaletteVocabularyTests` asserts the absence by name over the type's own stored properties, so
// adding one later fails the host suite rather than shipping.
//
// ``VisualEmphasis/emphasis(for:)`` already makes an outcome-derived colour unreachable, because it
// is never shown an outcome. This file makes it unrepresentable as well: even given a verdict,
// there is nothing here to tint it with.
//
// # What colour is allowed to mean
//
// Exactly two content surfaces are tinted, and both only restate what their own approved wording
// already says:
//
//   * ``caution``, for the notice that the two evidence lanes appear inconsistent. The notice's
//     approved sentence says the lanes disagree; the tint repeats it and resolves nothing.
//   * ``critical``, for the single Analysis Error message. That is a failure of the application's
//     own work, stated in words by approved error copy, and never one of the three labels - so it
//     cannot be read as a verdict about an image (Requirement 11.17).
//
// Everything else is neutral. ``accent`` marks a control and nothing else: a deep navy in light
// mode and a pale blue in dark mode, chosen so it reads as an instrument rather than as an outcome,
// and so it sits nowhere near the red-green axis a viewer would read as pass or fail.
//
// # Measured, not asserted in prose
//
// Every ratio quoted below is computed from these exact components by `PaletteContrastTests`, which
// implements the WCAG relative-luminance formula and fails the host suite when a pair drops below
// its threshold. The numbers in this comment are the test's output, not an estimate:
//
//   * body and secondary text meet 4.5:1 on every surface they are drawn on, in both appearances
//     (measured range 6.56:1 to 17.79:1);
//   * ``controlBorder`` meets 3:1 against both the page and a card, in both appearances
//     (3.26:1 to 3.97:1), because it bounds containers that hold controls;
//   * ``border`` is decorative separation between non-interactive cards and is deliberately softer
//     than 3:1. WCAG 1.4.11 scopes non-text contrast to control boundaries and meaningful
//     graphics; a hairline between two inert cards is neither, and forcing it to 3:1 draws a heavy
//     grey rule that fights the whole visual language. ``controlBorder`` exists so the distinction
//     is a token rather than a judgement made per call site.

/// One sRGB colour, as eight-bit components.
///
/// Deliberately framework-free and outside any `canImport` guard, for one reason: the contrast
/// tests have to be able to read the numbers. A `Color` is opaque - a test can construct one and
/// cannot get its components back out - so a palette built directly from `Color` values can only be
/// checked by eye. Keeping the components as data means the ratios are arithmetic.
public struct ColorComponents: Hashable, Sendable {
    /// Red, green, and blue, each 0 through 255.
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG relative luminance.
    ///
    /// The formula from WCAG 2.1, written out rather than approximated, because the thresholds this
    /// feeds are the accessibility claim.
    public var relativeLuminance: Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between this colour and another, from 1 to 21.
    ///
    /// Symmetric, so the argument order carries no meaning and a caller cannot get a better number
    /// by swapping foreground and background.
    public func contrastRatio(against other: ColorComponents) -> Double {
        let mine = relativeLuminance
        let theirs = other.relativeLuminance
        let lighter = max(mine, theirs)
        let darker = min(mine, theirs)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Which appearance a palette is for.
///
/// Named here rather than taken from the framework, so the palette and its tests stay framework-free.
public enum Appearance: String, Hashable, Sendable, CaseIterable {
    case light
    case dark
}

/// One appearance's colours.
///
/// A value rather than an asset catalog, so the components are readable by a host test and the
/// module carries no colour asset a build could resolve differently from the one that was measured.
public struct Palette: Hashable, Sendable {

    // MARK: Surfaces

    /// The page background.
    public let background: ColorComponents

    /// A card's own background.
    public let surface: ColorComponents

    /// A tinted inset's background, and the recessive fill behind a quiet row.
    public let inset: ColorComponents

    /// Decorative separation between non-interactive surfaces.
    public let border: ColorComponents

    /// The boundary of a container that holds controls. Meets 3:1 against page and card.
    public let controlBorder: ColorComponents

    // MARK: Text

    /// Body and headline text.
    public let textPrimary: ColorComponents

    /// Supporting text: an explanation, a limitation, a transparency row.
    public let textSecondary: ColorComponents

    // MARK: Controls

    /// The fill of the one action that moves a session forward.
    public let accent: ColorComponents

    /// Text and accessories drawn on ``accent``.
    public let onAccent: ColorComponents

    // MARK: The two tinted content surfaces

    /// The inconsistency notice's background.
    public let cautionSurface: ColorComponents

    /// The inconsistency notice's text.
    public let caution: ColorComponents

    /// The Analysis Error message's background.
    public let criticalSurface: ColorComponents

    /// The Analysis Error message's text.
    public let critical: ColorComponents

    /// The palette for one appearance. Total, so a new appearance would have to be given colours.
    public static func resolved(for appearance: Appearance) -> Palette {
        switch appearance {
        case .light: .light
        case .dark: .dark
        }
    }

    /// The light appearance.
    ///
    /// The background is a cool near-white rather than pure white: on an unbroken white page a
    /// white card has nothing to sit against, and the hairline would carry the whole boundary.
    public static let light = Palette(
        background: ColorComponents(0xF5, 0xF7, 0xFA),
        surface: ColorComponents(0xFF, 0xFF, 0xFF),
        inset: ColorComponents(0xEC, 0xEF, 0xF4),
        border: ColorComponents(0xD0, 0xD8, 0xE2),
        controlBorder: ColorComponents(0x7E, 0x8A, 0x9B),
        textPrimary: ColorComponents(0x14, 0x18, 0x1F),
        textSecondary: ColorComponents(0x4B, 0x55, 0x63),
        accent: ColorComponents(0x1E, 0x3A, 0x5F),
        onAccent: ColorComponents(0xFF, 0xFF, 0xFF),
        cautionSurface: ColorComponents(0xFF, 0xF4, 0xDE),
        caution: ColorComponents(0x7A, 0x52, 0x00),
        criticalSurface: ColorComponents(0xFD, 0xEB, 0xE8),
        critical: ColorComponents(0x9E, 0x24, 0x1A)
    )

    /// The dark appearance.
    ///
    /// Not the light palette inverted. The card surface is *lighter* than the page rather than
    /// darker, so elevation reads the same way in both appearances, and the borders are stronger
    /// than a naive inversion would make them - a divider that vanishes in one appearance is the
    /// most common way a themed layout loses its structure.
    public static let dark = Palette(
        background: ColorComponents(0x0E, 0x14, 0x20),
        surface: ColorComponents(0x19, 0x20, 0x2E),
        inset: ColorComponents(0x21, 0x2A, 0x3A),
        border: ColorComponents(0x31, 0x3D, 0x52),
        controlBorder: ColorComponents(0x66, 0x76, 0x8B),
        textPrimary: ColorComponents(0xF1, 0xF4, 0xF9),
        textSecondary: ColorComponents(0xA6, 0xB2, 0xC2),
        accent: ColorComponents(0xA9, 0xC9, 0xEF),
        onAccent: ColorComponents(0x0E, 0x14, 0x20),
        cautionSurface: ColorComponents(0x2E, 0x24, 0x10),
        caution: ColorComponents(0xF0, 0xC8, 0x78),
        criticalSurface: ColorComponents(0x33, 0x16, 0x12),
        critical: ColorComponents(0xF5, 0xAB, 0xA1)
    )
}

// MARK: - Emphasis and surface to colour

extension Palette {
    /// The text colour one emphasis is drawn in.
    ///
    /// Total switch, no `default`. Both evidence lanes reach this through
    /// ``VisualEmphasis/laneHeadline`` and ``VisualEmphasis/laneBody``, so they resolve to the same
    /// two colours as each other by construction (Requirements 7.1 and 7.8).
    ///
    /// The parameter is an emphasis. It is not an outcome, and there is no overload that takes one.
    public func foreground(for emphasis: VisualEmphasis) -> ColorComponents {
        switch emphasis {
        case .laneHeadline, .combinedSummary, .status, .navigationRow, .disclosureHeader:
            textPrimary
        case .laneBody, .limitation, .transparencyRow: textSecondary
        case .inconsistencyNotice: caution
        case .failureMessage: critical
        case .primaryAction: onAccent
        case .cancellationAction: textPrimary
        }
    }

    /// The background of one region's container, or `nil` when the region draws on the page.
    ///
    /// ``RegionSurface/card`` answers one value, which both evidence lanes share: a lane cannot be
    /// given a surface the other lane does not have, because they resolve through the same case.
    public func background(for surface: RegionSurface, region: ScreenRegion) -> ColorComponents? {
        switch surface {
        case .card, .rowGroup: self.surface
        case .inset: region == .failure ? criticalSurface : cautionSurface
        case .recessiveBlock, .centeredStatus, .controlStack: nil
        }
    }

    /// The border of one region's container, or `nil` when it draws none.
    ///
    /// A row group gets ``controlBorder`` because it holds controls; a card gets the softer
    /// decorative ``border`` because it does not.
    public func border(for surface: RegionSurface, region: ScreenRegion) -> ColorComponents? {
        switch surface {
        case .card: border
        case .rowGroup: controlBorder
        case .inset: region == .failure ? critical : caution
        case .recessiveBlock, .centeredStatus, .controlStack: nil
        }
    }

    /// Every text pair that must meet the 4.5:1 threshold, named for a failure report.
    ///
    /// Exposed as data so `PaletteContrastTests` enumerates the real pairs rather than a list
    /// written out a second time in the test and allowed to drift from this one.
    public var textPairs: [(name: String, foreground: ColorComponents, background: ColorComponents)]
    {
        [
            ("textPrimary on background", textPrimary, background),
            ("textPrimary on surface", textPrimary, surface),
            ("textPrimary on inset", textPrimary, inset),
            ("textSecondary on background", textSecondary, background),
            ("textSecondary on surface", textSecondary, surface),
            ("textSecondary on inset", textSecondary, inset),
            ("onAccent on accent", onAccent, accent),
            ("caution on cautionSurface", caution, cautionSurface),
            ("critical on criticalSurface", critical, criticalSurface),
        ]
    }

    /// Every non-text pair that must meet the 3:1 threshold.
    public var nonTextPairs:
        [(name: String, foreground: ColorComponents, background: ColorComponents)]
    {
        [
            ("controlBorder on background", controlBorder, background),
            ("controlBorder on surface", controlBorder, surface),
            ("accent on background", accent, background),
            ("accent on surface", accent, surface),
        ]
    }

    /// The WCAG threshold for normal-size text.
    public static let textContrastMinimum = 4.5

    /// The WCAG threshold for non-text UI boundaries.
    public static let nonTextContrastMinimum = 3.0
}
