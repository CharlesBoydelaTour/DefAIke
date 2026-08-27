import DefAIkeDomain

// The layout rules Requirements 12.8 and 12.10 fix, expressed as values.
//
// Requirement 12.8 asks for every Dynamic Type size through the largest accessibility size,
// with every evidence outcome, scope warning, privacy statement, and recovery action visible
// and reachable without overlap, clipping, or truncation. Requirement 12.10 asks that,
// while Reduce Motion is enabled, nonessential motion is replaced by a nonmoving state
// change conveying the same status.
//
// Both are ultimately claims about pixels on a device, and this module cannot measure pixels.
// What it can do is remove the decisions that make those claims fail. Every rule below is a
// one-case enum, so the failing alternative is not something a view can select:
//
//   * ``TextReflowPolicy`` has no "truncate" case, so no line limit, no tail ellipsis, and
//     no fixed line count is expressible.
//   * ``ContentScrollPolicy`` has no "fit to viewport" case, so content that grows past the
//     screen scrolls rather than being clipped or compressed.
//   * ``StatusChangeStyle`` has two cases and ``MotionPolicy`` chooses between them from the
//     Reduce Motion setting alone, so the reduced-motion branch cannot be forgotten - and
//     because the style is not a member of ``AccessibleElement``, the same semantics are
//     exposed either way.
//
// The layout axis is the one genuine decision, and it is a pure function of the text size:
// at an accessibility size the axis is vertical, because a horizontal row of labels and
// values is where overlap and clipping come from. It is a function rather than a constant so
// a test can assert the rule for every size, including the boundary.
//
// What this file does not contain: a width, a height, an inset, a spacing value, a font size,
// or a breakpoint. Those are framework-layer values, they are measured on a device, and a
// number written here would be exactly the fixed-width assumption Requirement 12.8 forbids.

/// One Dynamic Type size the application supports.
///
/// The platform's twelve sizes, named here rather than imported, so the policy stays a plain
/// value a host test can enumerate without a view framework. The view maps these onto the
/// framework's own type.
///
/// The last five are the accessibility sizes. Requirement 12.8 requires support "through the
/// largest accessibility text size", which is the last case, so the closed list is what makes
/// "every size" checkable.
public enum SupportedTextSize: String, Hashable, Sendable, CaseIterable {
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibility1 = "accessibility-1"
    case accessibility2 = "accessibility-2"
    case accessibility3 = "accessibility-3"
    case accessibility4 = "accessibility-4"
    case accessibility5 = "accessibility-5"

    /// Whether this is one of the five accessibility sizes.
    public var isAccessibilitySize: Bool {
        switch self {
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            true
        case .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge,
            .extraExtraExtraLarge:
            false
        }
    }

    /// The largest size the application must remain usable at (Requirement 12.8).
    public static let largestSupported = SupportedTextSize.accessibility5

    /// The five accessibility sizes, in ascending order.
    public static var accessibilitySizes: [SupportedTextSize] {
        allCases.filter(\.isAccessibilitySize)
    }
}

/// How text behaves when it does not fit.
///
/// One case by construction (Requirement 12.8). There is no line limit to set, no truncation
/// mode to choose, and no minimum scale factor to shrink text with, so a label cannot be cut
/// off by a layout decision made here.
public enum TextReflowPolicy: String, Hashable, Sendable, CaseIterable {
    /// Wrap onto as many lines as the text needs, and never truncate.
    case reflowWithoutTruncation = "reflow-without-truncation"
}

/// How content behaves when it exceeds the viewport.
///
/// One case by construction (Requirement 12.8). Reachability at the largest accessibility
/// sizes depends on scrolling, so "this screen fits" is not a state a view can assert.
public enum ContentScrollPolicy: String, Hashable, Sendable, CaseIterable {
    /// Scroll whenever the content is taller than the viewport, at every text size.
    case scrollWheneverContentExceedsViewport = "scroll-whenever-content-exceeds-viewport"
}

/// The direction a group of related fields is laid out in.
public enum LayoutAxis: String, Hashable, Sendable, CaseIterable {
    case vertical
    case horizontal
}

/// Whether a status change moves.
///
/// Two cases, chosen by ``MotionPolicy/statusChangeStyle(reduceMotion:)`` and by nothing
/// else. Both convey the same status, because the status text and its accessibility semantics
/// are the same values either way: neither ``AccessibleElement`` nor
/// ``StatusAnnouncement`` has a member for a style, so a reduced-motion screen cannot say
/// less than an animated one.
public enum StatusChangeStyle: String, Hashable, Sendable, CaseIterable {
    /// A moving indicator accompanies the status text.
    case animatedIndicator = "animated-indicator"

    /// A nonmoving state change accompanies the status text (Requirement 12.10).
    case staticStateChange = "static-state-change"
}

/// A surface whose visual treatment would otherwise move.
///
/// Enumerated so a release audit can list what Requirement 12.10 applies to, and so the
/// accessibility tests can check each one rather than checking the setting once. Every one of
/// these is nonessential motion: the status it decorates is always stated as text.
public enum MotionSensitiveSurface: String, Hashable, Sendable, CaseIterable {
    /// The indicator shown while analysis work is in flight.
    case activeWorkIndicator = "active-work-indicator"

    /// The change from one screen family to another.
    case screenFamilyTransition = "screen-family-transition"

    /// The appearance of a newly resolved evidence field.
    case evidenceFieldAppearance = "evidence-field-appearance"
}

/// The Reduce Motion substitution (Requirement 12.10).
public enum MotionPolicy: Sendable {
    /// The style one status change uses.
    ///
    /// A pure function of the setting, with no surface parameter: every
    /// ``MotionSensitiveSurface`` in this application carries nonessential motion, so there
    /// is no surface for which the answer differs and therefore no branch that could keep one
    /// of them moving.
    public static func statusChangeStyle(reduceMotion: Bool) -> StatusChangeStyle {
        reduceMotion ? .staticStateChange : .animatedIndicator
    }

    /// Whether every motion-sensitive surface has a nonmoving alternative.
    ///
    /// Always true, because ``statusChangeStyle(reduceMotion:)`` is total and returns
    /// ``StatusChangeStyle/staticStateChange`` for every surface when the setting is on.
    /// Exposed so the release audit can assert it per surface rather than trusting the
    /// function was called.
    public static func hasNonmovingAlternative(for surface: MotionSensitiveSurface) -> Bool {
        // The surface is accepted, and deliberately not consulted. Every motion-sensitive
        // surface here is nonessential, so an answer that varied by surface would be the
        // beginning of an exception.
        MotionSensitiveSurface.allCases.contains(surface)
            && statusChangeStyle(reduceMotion: true) == .staticStateChange
    }
}

/// The layout rules every screen in this application follows.
///
/// A value rather than a set of view modifiers, so the accessibility tests can assert the
/// policy without rendering anything, and the views have one place to read it from.
public struct AdaptiveLayoutPolicy: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// The policy every screen uses. There is no second one.
    public static let standard = AdaptiveLayoutPolicy()

    /// How text behaves when it does not fit. Always reflow, never truncate.
    public let textReflow: TextReflowPolicy = .reflowWithoutTruncation

    /// How content behaves when it exceeds the viewport. Always scrollable.
    public let contentScroll: ContentScrollPolicy = .scrollWheneverContentExceedsViewport

    /// The minimum activation area every interactive control provides.
    public let activationArea: MinimumActivationArea = .requiredMinimum

    init() {}

    /// The axis a group of related fields is laid out in, at one text size.
    ///
    /// Vertical at every accessibility size, because a horizontal pairing of label and value
    /// is where overlap and clipping start once the text grows. Horizontal is permitted only
    /// below the accessibility sizes, and only for a group whose fields are short.
    public func axis(at size: SupportedTextSize) -> LayoutAxis {
        size.isAccessibilitySize ? .vertical : .horizontal
    }

    /// Every text size the application supports (Requirement 12.8).
    public var supportedTextSizes: [SupportedTextSize] { SupportedTextSize.allCases }

    /// The style a status change uses, at one Reduce Motion setting.
    public func statusChangeStyle(reduceMotion: Bool) -> StatusChangeStyle {
        MotionPolicy.statusChangeStyle(reduceMotion: reduceMotion)
    }
}
