#if canImport(SwiftUI)

import SwiftUI

// The framework-layer values the views measure and draw with.
//
// They live here, behind `canImport(SwiftUI)`, rather than in the framework-free policy layer, and
// that boundary is ``AdaptiveLayoutPolicy``'s rather than a new one: a width, an inset, or a font
// size is a value the framework resolves on a device, so a number written into the policy layer
// would be exactly the fixed-layout assumption Requirement 12.8 forbids. The policy layer keeps the
// *rules* - always scroll, always reflow, never truncate, 44 points minimum - and this file keeps
// the rhythm those rules are drawn on.
//
// Three things are absent on purpose, and each absence is a requirement rather than a taste:
//
//   * **No font size.** Every typographic token is a `Font.TextStyle`, so text scales with the
//     user's Dynamic Type setting through the largest accessibility size (Requirement 12.8). There
//     is no `.system(size:)` in this module, and `TypographyTests` asserts that by sweeping the
//     source.
//   * **No width, and no breakpoint.** A screen's content width comes from its container. The one
//     horizontal measurement is a readable-measure ceiling, which is not a breakpoint: there is no
//     size class to read, no device class to enumerate, and no conditional to get the wrong way
//     round.
//   * **No length that encodes a magnitude.** Nothing here is a bar length, a fill fraction, or a
//     gauge radius, because Requirement 8.13 bans a graphical encoding equivalent to a probability
//     or confidence value and this application draws no such shape.
//
// The spacing scale is a 4-point rhythm and is deliberately short. A long scale is one nobody can
// hold in their head, and the point of a token is that two surfaces separated by ``Space/section``
// are separated by the same amount.

/// The spacing rhythm, in points.
///
/// Named by role rather than by size, so a caller asks for the separation it means instead of
/// picking a number, and a change to the rhythm is one edit here.
enum Space {
    /// Between a label and the state immediately belonging to it.
    static let hairGap: CGFloat = 4

    /// Between tightly related lines inside one field.
    static let tight: CGFloat = 8

    /// Between sibling fields inside one region.
    static let inner: CGFloat = 12

    /// Between a container's edge and its content.
    static let padding: CGFloat = 16

    /// Between one region and the next.
    static let section: CGFloat = 24

    /// Between a screen's major blocks.
    static let block: CGFloat = 32

    /// The breathing room a centered empty or status composition needs above and below.
    static let generous: CGFloat = 48

    /// The horizontal page margin.
    static let pageMargin: CGFloat = 20
}

/// Page-level measurements.
enum Layout {
    /// The widest a column of text is allowed to become, in points.
    ///
    /// A ceiling rather than a breakpoint, and the difference matters: there is no size class to
    /// read and no device class to enumerate. On a phone the ceiling is never reached, so it changes
    /// nothing; on anything wider it stops the limitation statements from running the full width of
    /// the screen, which is where long-form text stops being readable.
    static let readableWidth: CGFloat = 560
}

/// Corner radii, in points.
enum Radius {
    /// An evidence card or a row group.
    static let card: CGFloat = 16

    /// A tinted inset: a notice, a failure message.
    static let inset: CGFloat = 12

    /// A control.
    static let control: CGFloat = 14
}

/// Line weights and decorative sizes, in points.
enum Stroke {
    /// A hairline border or divider. One point, so it reads as a boundary rather than a frame.
    static let hairline: CGFloat = 1

    /// A decorative accessory beside text.
    static let accessory: CGFloat = 20

    /// The nonmoving in-flight dot used under Reduce Motion.
    static let indicatorDot: CGFloat = 10

    /// The decorative mark on a screen with no content of its own.
    static let mark: CGFloat = 64
}

/// The one opacity this module uses, for a tinted inset's border.
///
/// A single named value rather than a number at each call site, so a border tint cannot be made
/// heavier on one screen than another. It applies only to the two tinted content surfaces, whose
/// text colour already meets 4.5:1 against its own fill at full strength.
enum Tint {
    /// How strongly a tinted inset's border states its own edge.
    static let insetBorder: Double = 0.28
}

/// Motion.
///
/// One transition duration, not one per surface. Every animated surface in this application is a
/// screen-family change or the appearance of a resolved field, both of which cover the same
/// distance, and ``MotionPolicy`` already replaces all of it with a nonmoving state change when
/// Reduce Motion is on (Requirement 12.10).
enum Motion {
    /// The SwiftUI animation for a screen-family change, or `nil` under Reduce Motion.
    ///
    /// `nil` rather than a zero-duration animation, so the reduced branch performs no animation at
    /// all instead of a fast one. The caller passes the environment value; this function decides
    /// nothing about whether motion is wanted, which is ``MotionPolicy``'s job.
    static func familyTransition(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeOut(duration: 0.26)
    }
}

// MARK: - Colour bridge

extension Color {
    /// One `Color` from measured components.
    ///
    /// The single bridge between the framework-free palette and the framework. A named initializer
    /// rather than a hex-string parser: a parser has a failure case, and a colour that silently
    /// falls back to black on a typo is how a measured contrast ratio stops describing what is
    /// actually on screen.
    init(_ components: ColorComponents) {
        self.init(
            .sRGB,
            red: Double(components.red) / 255,
            green: Double(components.green) / 255,
            blue: Double(components.blue) / 255,
            opacity: 1
        )
    }
}

extension Appearance {
    /// The appearance one framework colour scheme corresponds to.
    ///
    /// An unknown future scheme maps to light rather than dark, matching the framework's own
    /// default, so a new case cannot silently produce an unmeasured palette.
    init(_ scheme: ColorScheme) {
        switch scheme {
        case .dark: self = .dark
        case .light: self = .light
        @unknown default: self = .light
        }
    }
}

// MARK: - Typography

extension VisualEmphasis {
    /// The Dynamic Type text style this emphasis is drawn at.
    ///
    /// A text style and never a point size, so every string scales with the user's setting
    /// (Requirement 12.8). Total switch, no `default`, so a new emphasis has to choose one.
    ///
    /// ``laneHeadline`` answers one value for both lanes, because ``VisualEmphasis`` gives the two
    /// lanes one shared case - the type-level form of "neither lane is ranked".
    var textStyle: Font.TextStyle {
        switch self {
        // `headline` rather than `title3`, and a screenshot is why. The two lanes share this case,
        // so they are styled identically - but the pixel lane's headline is a four-word label while
        // the provenance lane's is a whole sentence, and at `title3` semibold that sentence became a
        // wall of large bold text that visually dominated the lane beside it. Identical styling is
        // not the same as identical visual mass when the content lengths differ by four times.
        // Dropping one step keeps the label prominent and stops the sentence shouting.
        case .laneHeadline: .headline
        case .combinedSummary, .status, .failureMessage, .primaryAction: .headline
        case .laneBody, .inconsistencyNotice, .cancellationAction, .navigationRow,
            .disclosureHeader:
            .subheadline
        case .limitation, .transparencyRow: .footnote
        }
    }

    /// The weight this emphasis is drawn at.
    var weight: Font.Weight {
        switch self {
        case .laneHeadline, .primaryAction: .semibold
        case .combinedSummary, .status, .failureMessage, .cancellationAction,
            .disclosureHeader:
            .medium
        case .laneBody, .inconsistencyNotice, .limitation, .navigationRow, .transparencyRow:
            .regular
        }
    }

    /// The font for this emphasis.
    var font: Font { .system(textStyle, weight: weight) }

    /// How this emphasis's text is aligned.
    ///
    /// Derived rather than chosen at the call site, so the same emphasis is aligned the same way on
    /// every screen. Only status text is centered: it sits in a centered composition with the work
    /// indicator, and a leading-aligned sentence under a centered mark reads as a mistake.
    /// Everything else is leading, because a centered paragraph is harder to read and the
    /// limitation statements are the longest text in the application.
    var textAlignment: TextAlignment {
        switch self {
        case .status: .center
        case .laneHeadline, .laneBody, .combinedSummary, .inconsistencyNotice, .limitation,
            .failureMessage, .primaryAction, .cancellationAction, .navigationRow,
            .transparencyRow, .disclosureHeader:
            .leading
        }
    }

    /// The frame alignment matching ``textAlignment``.
    ///
    /// Derived from the text alignment rather than declared beside it, so a block cannot be pushed
    /// to one edge while its text is aligned to the other.
    var frameAlignment: Alignment {
        switch textAlignment {
        case .center: .center
        case .leading, .trailing: .leading
        }
    }
}

#endif
