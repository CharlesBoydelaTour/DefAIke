#if canImport(SwiftUI)

import DefAIkeDomain
import SwiftUI

// Applying one ``AccessibleElement`` to one view, and nothing else.
//
// Every accessibility decision was already made as data. This file is the mechanical part: it
// maps a closed trait vocabulary onto the framework's own traits, turns a reading position into
// the framework's ordering value, and turns a point count into the framework's unit. There is no
// branch here that could decide an element is a header on one screen and a button on another,
// because the role decided that and the role is not an input to any of these functions.
//
// Keeping the mapping this thin is the point. A semantics bug is then a wrong value in a snapshot
// a host test can read, not a missing modifier in a `body` only a device can observe. The one
// judgement this file does make is what to do when approved text is unavailable: it renders
// nothing. A control with no name and a field with no words are both worse than an absence, and
// an absence is what every other layer in this module already does with an unapproved surface.

extension AccessibilityTrait {
    /// The framework trait this vocabulary entry maps to.
    ///
    /// Total switch, no `default`, so a new trait has to be mapped rather than silently dropped.
    var frameworkTrait: AccessibilityTraits {
        switch self {
        case .button: .isButton
        case .header: .isHeader
        case .staticText: .isStaticText
        case .updatesFrequently: .updatesFrequently
        }
    }
}

extension AccessibleElement {
    /// Every framework trait this element carries, as one value.
    ///
    /// Built by unioning ``AccessibleElement/traits``, which is itself derived from the role, so
    /// the applied traits cannot disagree with the audited ones (Requirement 12.3).
    var frameworkTraits: AccessibilityTraits {
        traits.reduce(into: AccessibilityTraits()) { combined, trait in
            combined.formUnion(trait.frameworkTrait)
        }
    }
}

extension MinimumActivationArea {
    /// The minimum width, in the framework's unit.
    var frameworkWidth: CGFloat { CGFloat(widthPoints) }

    /// The minimum height, in the framework's unit.
    var frameworkHeight: CGFloat { CGFloat(heightPoints) }
}

extension SupportedTextSize {
    /// The supported size one framework size corresponds to.
    ///
    /// Total over the framework's own vocabulary. A size the framework adds later maps to the
    /// largest supported size rather than to a smaller one, because treating an unknown larger
    /// size as `large` is how truncation returns.
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibility1
        case .accessibility2: self = .accessibility2
        case .accessibility3: self = .accessibility3
        case .accessibility4: self = .accessibility4
        case .accessibility5: self = .accessibility5
        @unknown default: self = .largestSupported
        }
    }
}

// MARK: - The modifier

/// Applies one element's accessibility semantics and layout requirements to a view.
///
/// Six requirements, one modifier, no options:
///
///   * the label, from the element's approved address (Requirement 12.1);
///   * the value, when the element has one distinct from its label (Requirement 12.2);
///   * the traits its role requires (Requirement 12.3);
///   * its position in the reading and action order (Requirement 12.4);
///   * text that reflows to as many lines as it needs and is never truncated
///     (Requirement 12.8); and
///   * a 44 by 44 point activation area for an operable element, with the whole of that area
///     hit-testable rather than only the drawn glyphs (Requirement 12.9).
///
/// The label and value are supplied already resolved. Resolution can fail, and a view that
/// renders an element it could not resolve would show an unnamed control, so the failure is
/// handled by not building the view at all - see ``AccessibleElementView``.
///
/// `children: .ignore` collapses the element to one accessible thing with exactly the label and
/// value computed upstream. When a field shows both its name and its state as two pieces of
/// visible text, that is a layout decision; an assistive technology should still hear one element
/// with one label and one value, not two unlabelled strings.
struct AccessibleSemantics: ViewModifier {
    /// The element whose semantics these are.
    let element: AccessibleElement

    /// The resolved label text.
    let label: String

    /// The resolved value text, when the element has a value.
    let value: String?

    /// How many elements the screen exposes, used to turn a position into a descending priority.
    let elementCount: Int

    /// This element's position in the reading order.
    let readingIndex: Int

    /// The weight this element is drawn at, derived from its identity and never from an outcome.
    var emphasis: VisualEmphasis { .emphasis(for: element.identity) }

    func body(content: Content) -> some View {
        content
            // Reflow, never truncate. `fixedSize` vertically lets the text take the height it
            // needs; the absence of any line limit is what keeps it from being cut off.
            .fixedSize(horizontal: false, vertical: true)
            // The alignment comes from the emphasis rather than from a literal, so the same weight
            // is aligned the same way on every screen and a block cannot be centred on one and
            // leading on another.
            .multilineTextAlignment(emphasis.textAlignment)
            // An operable element gets the required activation area, and the whole rectangle is
            // hit-testable so the target is the area rather than the drawn content.
            .frame(
                minWidth: element.activationArea?.frameworkWidth,
                minHeight: element.activationArea?.frameworkHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: value ?? ""))
            .accessibilityAddTraits(element.frameworkTraits)
            // Descending priority from the reading position, so the framework's ordering matches
            // the snapshot's array order exactly. Derived from the position rather than authored,
            // so an element cannot be given a priority that contradicts where it appears.
            .accessibilitySortPriority(Double(elementCount - readingIndex))
    }
}

extension View {
    /// Applies one element's semantics, with its label and value already resolved.
    func accessibleSemantics(
        _ element: AccessibleElement,
        label: String,
        value: String?,
        elementCount: Int,
        readingIndex: Int
    ) -> some View {
        modifier(
            AccessibleSemantics(
                element: element,
                label: label,
                value: value,
                elementCount: elementCount,
                readingIndex: readingIndex
            )
        )
    }
}

// MARK: - One element

/// Renders one exposed element, or nothing when its approved text cannot be resolved.
///
/// Two shapes only: static text for a content role, and a button for an operable one. There is no
/// third shape, so an operable element cannot be drawn as text a Switch Control scanner would skip
/// and a content field cannot become tappable.
///
/// A field that has both a name and a state shows both, stacked along `axis` - vertical at every
/// accessibility text size, because a side-by-side name and value is where overlap and clipping
/// start once the text grows (Requirement 12.8).
///
/// `Text(verbatim:)` is deliberate. The string already came from the approved catalog through
/// ``AccessibleTextResolver``, and a second localized lookup on an already-resolved value is how a
/// key ends up on screen.
struct AccessibleElementView: View {
    /// The element to render.
    let element: AccessibleElement

    /// The resolver supplying approved text.
    let resolver: AccessibleTextResolver

    /// How many elements the screen exposes.
    let elementCount: Int

    /// This element's position in the reading order.
    let readingIndex: Int

    /// The axis a name-and-state pairing is laid out along, at the current text size.
    let axis: LayoutAxis

    /// The region this element is grouped into, which decides which control treatment it gets.
    let region: ScreenRegion

    /// The measured palette for the current appearance.
    let palette: Palette

    /// Whether this element's group is expanded, or `nil` when it is not a disclosure.
    ///
    /// Drives the framework's expanded trait as well as the glyph, so an assistive technology hears
    /// the state rather than only seeing it (Requirement 12.2).
    let isExpanded: Bool?

    /// What activating this element does, or `nil` for a content element.
    let action: (() -> Void)?

    /// The weight this element is drawn at.
    ///
    /// Derived from the identity through ``VisualEmphasis/emphasis(for:)``, which is never shown an
    /// outcome. This is the only thing that decides how the element looks.
    private var emphasis: VisualEmphasis { .emphasis(for: element.identity) }

    var body: some View {
        if let label = resolver.resolvedText(for: element.label) {
            let value = element.value.flatMap { resolver.resolvedText(for: $0) }
            if element.isOperable, let action {
                control(label: label, value: value, action: action)
            } else {
                visibleText(label: label, value: value)
                    .foregroundStyle(Color(palette.foreground(for: emphasis)))
                    .accessibleSemantics(
                        element,
                        label: label,
                        value: value,
                        elementCount: elementCount,
                        readingIndex: readingIndex
                    )
            }
        }
    }

    /// One operable element, in the control treatment its emphasis calls for.
    ///
    /// Three treatments, chosen by emphasis rather than by region or by call site: the one filled
    /// action that moves a session forward, the bordered control that stops active work, and a row
    /// inside a grouped container. A `Button` in every branch, so an operable element is never drawn
    /// as text a Switch Control scanner would skip.
    @ViewBuilder
    private func control(label: String, value: String?, action: @escaping () -> Void) -> some View {
        let semantics = { (view: AnyView) in
            view.accessibleSemantics(
                element,
                label: label,
                value: value,
                elementCount: elementCount,
                readingIndex: readingIndex
            )
        }

        switch emphasis {
        case .primaryAction:
            semantics(
                AnyView(
                    Button(action: action) {
                        HStack(spacing: Space.tight) {
                            // Decoration yields to text at the accessibility sizes. At those sizes
                            // the label wraps to three or more lines and a vertically centred glyph
                            // ends up floating beside the middle line, which reads as a mistake -
                            // and the glyph says nothing the label does not, so the honest thing is
                            // to give it the space back.
                            //
                            // The condition is the layout policy's own signal rather than a new
                            // breakpoint: `AdaptiveLayoutPolicy.axis(at:)` answers `.vertical`
                            // exactly at the accessibility sizes, so there is one place that decides
                            // what "large text" means and this is not a second one.
                            if axis == .horizontal {
                                DecorativeSelectionGlyph()
                            }
                            visibleText(label: label, value: value)
                        }
                        .foregroundStyle(Color(palette.foreground(for: emphasis)))
                    }
                    .buttonStyle(PrimaryActionStyle(palette: palette))
                )
            )
        case .cancellationAction:
            semantics(
                AnyView(
                    Button(action: action) {
                        visibleText(label: label, value: value)
                            .foregroundStyle(Color(palette.foreground(for: emphasis)))
                    }
                    .buttonStyle(SecondaryActionStyle(palette: palette))
                )
            )
        case .disclosureHeader:
            // The expanded state is spoken as an approved word, not left to the glyph
            // (Requirements 12.2 and 12.7). Which of the two words is resolved is view state's
            // decision; the words themselves come from the catalog like every other string here.
            let expansionState = (isExpanded == true)
                ? ChromeCopySurface.disclosureExpandedState
                : ChromeCopySurface.disclosureCollapsedState
            let stateValue = resolver.resolvedText(
                for: .approvedChromeCopy(ChromeCopyReference(expansionState))
            )
            Button(action: action) {
                HStack(spacing: Space.tight) {
                    visibleText(label: label, value: nil)
                    if axis == .horizontal {
                        DecorativeExpansionGlyph(
                            isExpanded: isExpanded ?? false,
                            palette: palette
                        )
                    }
                }
                .foregroundStyle(Color(palette.foreground(for: emphasis)))
            }
            .buttonStyle(GroupedRowStyle(palette: palette))
            .accessibleSemantics(
                element,
                label: label,
                value: stateValue,
                elementCount: elementCount,
                readingIndex: readingIndex
            )
        case .navigationRow, .transparencyRow, .laneHeadline, .laneBody, .combinedSummary,
            .inconsistencyNotice, .limitation, .status, .failureMessage:
            semantics(
                AnyView(
                    Button(action: action) {
                        HStack(spacing: Space.tight) {
                            visibleText(label: label, value: value)
                            // Dropped at the accessibility sizes for the same reason as the selection
                            // glyph above: it is a decorative affordance cue, and beside four lines of
                            // text it floats rather than points.
                            if axis == .horizontal {
                                DecorativeDisclosureGlyph(palette: palette)
                            }
                        }
                        .foregroundStyle(Color(palette.foreground(for: emphasis)))
                    }
                    .buttonStyle(GroupedRowStyle(palette: palette))
                )
            )
        }
    }

    /// The visible text: the label alone, or the label and its state along `axis`.
    ///
    /// The font comes from the emphasis, so a lane headline is a lane headline on every screen.
    @ViewBuilder
    private func visibleText(label: String, value: String?) -> some View {
        if let value {
            switch axis {
            case .vertical:
                VStack(alignment: .leading, spacing: Space.hairGap) {
                    Text(verbatim: label).font(emphasis.font)
                    Text(verbatim: value).font(emphasis.font)
                }
                .frame(maxWidth: .infinity, alignment: emphasis.frameAlignment)
            case .horizontal:
                HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                    Text(verbatim: label).font(emphasis.font)
                    Text(verbatim: value).font(emphasis.font)
                }
                .frame(maxWidth: .infinity, alignment: emphasis.frameAlignment)
            }
        } else {
            Text(verbatim: label)
                .font(emphasis.font)
                .frame(maxWidth: .infinity, alignment: emphasis.frameAlignment)
        }
    }
}

#endif
