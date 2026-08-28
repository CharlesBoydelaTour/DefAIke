#if canImport(SwiftUI)

import SwiftUI

// The drawn primitives, and the rule every one of them obeys.
//
// Each view here is decoration around text that has already been resolved from approved copy. None
// of them takes a `String`, none builds a `Text`, and none is shown an outcome. What they take is a
// ``RegionSurface``, a ``VisualEmphasis``, or nothing at all - so a component cannot become the
// place a verdict acquires a colour.
//
// Every non-text visual in this file is hidden from assistive technology. That is Requirement 12.7
// as applied here: a decoration may accompany text, it may not replace text, and it may never be the
// channel a status travels on. ``AccessoryPresentation`` has exactly one case for the same reason,
// and it says the same thing about the model layer.
//
// Symbols are drawn from SF Symbols, which is a vector family that scales with Dynamic Type and
// adapts to appearance. Two rules keep them honest: every one is `accessibilityHidden`, and every
// one accompanies visible text that carries the whole meaning. Remove every glyph in this file and
// nothing a user needs to know disappears - which is the test for whether a glyph is decorative.

// MARK: - Region containers

/// Applies one region's container treatment.
///
/// The treatment comes from the region's own ``ScreenRegion/surface``, so a region cannot be drawn
/// as a card on one screen and an inset on another, and the two evidence lanes cannot differ from
/// each other because they resolve through the same case.
struct RegionContainer: ViewModifier {
    /// The region being drawn.
    let region: ScreenRegion

    /// The palette for the current appearance.
    let palette: Palette

    func body(content: Content) -> some View {
        let surface = region.surface
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(borderOverlay)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// The inner padding this surface uses.
    ///
    /// A region drawn directly on the page takes none: it is already inside the page margin, and a
    /// second inset would push long-form text into a narrower column than the text above it.
    private var padding: CGFloat {
        switch region.surface {
        case .card, .inset, .rowGroup: Space.padding
        case .recessiveBlock, .centeredStatus, .controlStack: 0
        }
    }

    private var radius: CGFloat {
        switch region.surface {
        case .card, .rowGroup: Radius.card
        case .inset: Radius.inset
        case .recessiveBlock, .centeredStatus, .controlStack: 0
        }
    }

    @ViewBuilder
    private var background: some View {
        if let fill = palette.background(for: region.surface, region: region) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(fill))
        }
    }

    /// The border, at full strength for a structural boundary and tinted for an inset.
    ///
    /// A tinted inset's border restates the fill it already has, so it is drawn back; a card or row
    /// group's border is the boundary itself and is drawn at full strength.
    @ViewBuilder
    private var borderOverlay: some View {
        if let stroke = palette.border(for: region.surface, region: region) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    Color(stroke).opacity(region.surface == .inset ? Tint.insetBorder : 1),
                    lineWidth: Stroke.hairline
                )
        }
    }
}

extension View {
    /// Draws this view as one region's container.
    func regionContainer(_ region: ScreenRegion, palette: Palette) -> some View {
        modifier(RegionContainer(region: region, palette: palette))
    }
}

// MARK: - The in-flight indicator

/// The in-flight work indicator, and the Reduce Motion substitution for it (Requirement 12.10).
///
/// Two properties make it safe:
///
///   * it is hidden from assistive technology, so it can never be the channel a status travels on
///     (Requirement 12.7). What a user hears about active work comes from the status text;
///   * it carries no value, no fraction, and no magnitude, so it is not a graphical encoding of a
///     probability or confidence and there is nothing in it to read as one (Requirement 8.13).
///
/// Under Reduce Motion the moving indicator is replaced by a nonmoving one that appears and
/// disappears with the same state, so the same state change is conveyed without motion. The choice
/// comes from ``MotionPolicy`` rather than from an `if` here, so the reduced branch cannot be
/// forgotten.
struct WorkIndicatorView: View {
    /// Whether the user has asked for reduced motion.
    let reduceMotion: Bool

    /// The palette for the current appearance.
    let palette: Palette

    var body: some View {
        Group {
            switch MotionPolicy.statusChangeStyle(reduceMotion: reduceMotion) {
            case .animatedIndicator:
                // The framework's own indeterminate indicator. Deliberately the no-argument
                // initializer: `ProgressView(value:)` would draw a fill fraction, which is exactly
                // the graphical magnitude Requirement 8.13 bans.
                ProgressView()
                    .tint(Color(palette.textSecondary))
            case .staticStateChange:
                // A plain dot rather than a spinner: it states "work is in flight" by being present
                // and stops stating it by being absent, with nothing moving either way.
                //
                // Deliberately a dot and not a bar. A bar, gauge, or meter reads as a filled
                // magnitude; a dot has no fill fraction to misread.
                Circle()
                    .fill(Color(palette.textSecondary))
                    .frame(width: Stroke.indicatorDot, height: Stroke.indicatorDot)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Decorative marks

/// The decorative mark on a screen that has no content of its own.
///
/// The ready screen shows one control and one sentence. Without a mark it reads as a screen that
/// failed to load; with one it reads as a starting point. It says nothing the control does not
/// already say, which is why it is hidden.
struct DecorativeMark: View {
    /// The palette for the current appearance.
    let palette: Palette

    /// Sized by frame rather than by font size, for two reasons. A fixed *font* size is the one
    /// shape this module bans outright, because it is how text stops scaling with Dynamic Type; and
    /// a mark that did scale with the text setting would grow to dominate the screen at
    /// accessibility5 and push the control it decorates out of reach. A framed decoration scales
    /// with neither, which is correct for something that says nothing.
    var body: some View {
        Image(systemName: "viewfinder")
            .resizable()
            .scaledToFit()
            .frame(width: Stroke.mark, height: Stroke.mark)
            .foregroundStyle(Color(palette.controlBorder))
            .accessibilityHidden(true)
    }
}

/// A decorative trailing glyph on a row that opens another screen.
///
/// The affordance cue only. The row's approved label states where it goes, and this states nothing.
struct DecorativeDisclosureGlyph: View {
    /// The palette for the current appearance.
    let palette: Palette

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Color(palette.textSecondary))
            .accessibilityHidden(true)
    }
}

/// A decorative glyph showing whether a collapsible group is open.
///
/// Decorative because the state also travels as the framework's expanded trait, which is what an
/// assistive technology reads. Remove the glyph and nothing a user needs to know disappears.
struct DecorativeExpansionGlyph: View {
    /// Whether the group is open.
    let isExpanded: Bool

    /// The palette for the current appearance.
    let palette: Palette

    var body: some View {
        // Two distinct glyphs rather than one rotated one: a rotation is motion, and this state
        // change has to be conveyable without it (Requirement 12.10). Swapping the symbol conveys
        // the same thing with nothing moving.
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Color(palette.textSecondary))
            .accessibilityHidden(true)
    }
}

/// A decorative leading glyph on the one action that starts a session.
struct DecorativeSelectionGlyph: View {
    var body: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .font(.system(.subheadline, weight: .semibold))
            .accessibilityHidden(true)
    }
}

// MARK: - Control styles

/// The filled primary action.
///
/// Press feedback is an opacity change on the fill, never a scale or an offset, so pressing it moves
/// no surrounding content and causes no jitter. The label's own minimum frame comes from the
/// element's ``MinimumActivationArea``, applied in `AccessibleSemantics`, so this style adds
/// padding rather than a height.
struct PrimaryActionStyle: ButtonStyle {
    /// The palette for the current appearance.
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Space.padding)
            .padding(.vertical, Space.inner)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color(palette.accent).opacity(configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A bordered secondary action: the control that stops active work.
///
/// Bordered rather than filled, so the one filled control on any screen is the one that moves a
/// session forward. The border is ``Palette/controlBorder``, which meets 3:1, because it is the
/// boundary that identifies this control.
struct SecondaryActionStyle: ButtonStyle {
    /// The palette for the current appearance.
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Space.padding)
            .padding(.vertical, Space.inner)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color(palette.inset).opacity(configuration.isPressed ? 1 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color(palette.controlBorder), lineWidth: Stroke.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A row inside a grouped container.
///
/// Press feedback fills the row rather than moving it, for the same reason as above.
struct GroupedRowStyle: ButtonStyle {
    /// The palette for the current appearance.
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .fill(Color(palette.inset).opacity(configuration.isPressed ? 1 : 0))
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Vertical balance

/// An invisible view exactly as tall as the scroll viewport.
///
/// Behind a sparse screen in a `ZStack`, this is what centres the content vertically. A `ZStack`
/// takes the height of its tallest child, so:
///
///   * a screen with little content - ready, importing, active, cancelled - is shorter than this
///     spacer, so the stack is viewport-tall and the content sits in the middle of it;
///   * a screen with a full report is taller than the spacer, so the stack takes the *content's*
///     height and nothing is constrained, compressed, or clipped.
///
/// That is a minimum height rather than a fixed one, which is the whole reason for doing it this
/// way. The obvious implementation reads the viewport with a `GeometryReader` and sets a height, and
/// a fixed height is exactly what clips text at the largest accessibility sizes - so
/// `GeometryReader` is banned module-wide and `noViewCanTruncateOrClipText` enforces the ban.
/// `containerRelativeFrame` asks the scroll container for its length without taking over the
/// layout, and the `ZStack` turns that into a floor instead of a ceiling.
///
/// `hidden()` rather than a clear fill: it keeps the view in the layout while drawing nothing, and
/// it needs no colour, so this stays the one decorative view with no palette at all.
struct ViewportHeightSpacer: View {
    var body: some View {
        Rectangle()
            .hidden()
            .containerRelativeFrame(.vertical)
            .accessibilityHidden(true)
    }
}

// MARK: - Dividers

/// A hairline between rows in a grouped container.
///
/// Decorative: the rows are separate accessible elements whatever is drawn between them.
///
/// Sized with `maxHeight` rather than a fixed `height`, and that is not incidental. A fixed height is
/// the shape that clips text, so the module bans it outright and `noViewCanTruncateOrClipText`
/// enforces the ban by sweeping every source. A flexible rectangle asked for at most one point
/// resolves to exactly one point, so the hairline needs no exception to a rule worth keeping whole.
struct RowDivider: View {
    /// The palette for the current appearance.
    let palette: Palette

    var body: some View {
        Rectangle()
            .fill(Color(palette.border))
            .frame(maxWidth: .infinity, maxHeight: Stroke.hairline)
            .accessibilityHidden(true)
    }
}

#endif
