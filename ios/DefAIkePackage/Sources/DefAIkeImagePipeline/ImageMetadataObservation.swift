import DefAIkeDomain
import CoreGraphics
import Foundation
import ImageIO

// Deciding, for each of the three metadata fields the contract governs, which one of
// the four states was actually observed.
//
// Requirement 3.7 fixes the vocabulary: valid, absent, malformed, and unsupported, for
// orientation, embedded color profile, and alpha. Requirement 3.8 then requires the
// handling the bound contract assigns to *the observed state*. So the observation has
// to be a total function into those four states, and it has to be decided from
// evidence rather than from an assumption, because an input classified into the wrong
// state gets the wrong contract action applied and nothing downstream can detect it.
//
// Two sources of evidence, and they are used for different things:
//
//   * The Image I/O properties dictionary, for what the *container declares*. This is
//     the only place a declaration exists: once Core Graphics has produced a
//     `CGImage`, every image has some color space and some alpha layout, so the
//     decoded image alone cannot distinguish "the container said nothing" from "the
//     container said sRGB".
//   * The decoded `CGImage`'s own format, for what the *decode actually produced*.
//     This is what the transform will operate on, so it decides whether an action is
//     applicable at all.
//
// Where the two disagree the state is ``ImageMetadataState/malformed``: a container
// that declares transparency the decode does not carry, or two different orientations,
// has no single state for an action to be applied to, and picking either one would be
// the implicit fallback the requirements forbid.
//
// The observation is a pure function of explicit evidence so that the malformed and
// unsupported branches are testable. Several of them cannot be produced by any encoder
// on a given host — Image I/O normalizes an out-of-range orientation to 1 while
// writing, for instance — and a branch that only exists for real containers is a
// branch that never gets exercised until a real user hits it.

// MARK: - Orientation

/// One TIFF/EXIF orientation value (tag 274), named by where the stored image's first
/// row and first column belong in the displayed image.
///
/// Only these eight values exist. Anything else a container declares is parseable but
/// names no orientation, which is ``ImageMetadataState/unsupported`` rather than
/// malformed: the bytes were read successfully, they just do not select a transform.
enum ExifOrientation: Int, Hashable, Sendable, CaseIterable {
    /// First row at top, first column at left. Stored order is display order.
    case topLeft = 1
    /// First row at top, first column at right. Mirrored horizontally.
    case topRight = 2
    /// First row at bottom, first column at right. Rotated 180 degrees.
    case bottomRight = 3
    /// First row at bottom, first column at left. Mirrored vertically.
    case bottomLeft = 4
    /// First row at left, first column at top. Transposed.
    case leftTop = 5
    /// First row at right, first column at top. Rotated 90 degrees clockwise.
    case rightTop = 6
    /// First row at right, first column at bottom. Transposed and rotated 180 degrees.
    case rightBottom = 7
    /// First row at left, first column at bottom. Rotated 90 degrees counterclockwise.
    case leftBottom = 8

    /// Whether applying this orientation exchanges width and height.
    ///
    /// The four values that place the stored image's first *row* on a vertical edge
    /// turn rows into columns. This is needed before the transform runs, to size the
    /// destination buffer, and it is deliberately not derived from the step list so a
    /// mis-sized allocation cannot be blamed on a step-table typo.
    var exchangesAxes: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: false
        case .leftTop, .rightTop, .rightBottom, .leftBottom: true
        }
    }

    /// The pixel permutation, as the sequence of Accelerate steps that performs it.
    ///
    /// Every value decomposes into at most one reflection followed by at most one
    /// quarter-turn, because those are the operations vImage provides for interleaved
    /// four-channel 8-bit data. The two transposing values (5 and 7) are the only ones
    /// that need both.
    ///
    /// A quarter turn here is counterclockwise, which is what
    /// `vImageRotate90_ARGB8888` counts. Clockwise rotations are therefore spelled as
    /// three counterclockwise turns; writing "1 turn" for orientation 6 would flip the
    /// image the wrong way round and still produce a plausible-looking result, which is
    /// why the geometry is checked pixel by pixel against an independent coordinate
    /// mapping in the tests rather than by eye.
    var steps: [PixelPermutationStep] {
        switch self {
        case .topLeft: []
        case .topRight: [.reflectHorizontally]
        case .bottomRight: [.rotateCounterclockwise(quarterTurns: 2)]
        case .bottomLeft: [.reflectVertically]
        case .leftTop: [.reflectHorizontally, .rotateCounterclockwise(quarterTurns: 1)]
        case .rightTop: [.rotateCounterclockwise(quarterTurns: 3)]
        case .rightBottom: [.reflectHorizontally, .rotateCounterclockwise(quarterTurns: 3)]
        case .leftBottom: [.rotateCounterclockwise(quarterTurns: 1)]
        }
    }
}

/// One Accelerate pixel-permutation step.
enum PixelPermutationStep: Hashable, Sendable {
    /// One to three quarter turns counterclockwise.
    case rotateCounterclockwise(quarterTurns: Int)
    /// Mirror across the vertical axis.
    case reflectHorizontally
    /// Mirror across the horizontal axis.
    case reflectVertically

    /// Whether this step exchanges width and height.
    var exchangesAxes: Bool {
        switch self {
        case .rotateCounterclockwise(let turns): turns % 2 == 1
        case .reflectHorizontally, .reflectVertically: false
        }
    }
}

// MARK: - The observation

/// The metadata state of one decoded image, for each field the contract governs.
///
/// `Sendable` and framework-free on purpose: this is what crosses from the
/// property-reading step into the transform, so the transform can be exercised
/// without an Image I/O dictionary and the states can be enumerated exhaustively in a
/// property test.
struct ObservedImageMetadata: Hashable, Sendable {
    /// The observed orientation state.
    let orientation: ImageMetadataState

    /// The single declared orientation, present only when ``orientation`` is
    /// ``ImageMetadataState/valid``.
    ///
    /// Absent in every other state by construction, so a malformed or unsupported
    /// declaration cannot be quietly applied as if it had been valid.
    let declaredOrientation: ExifOrientation?

    /// The observed embedded-color-profile state.
    let colorProfile: ImageMetadataState

    /// The observed alpha state.
    let alpha: ImageMetadataState

    /// Whether the decode actually produced an alpha channel.
    ///
    /// Distinct from ``alpha``: a container that declares transparency the decode did
    /// not produce is ``ImageMetadataState/malformed`` while carrying no alpha channel,
    /// and the transform needs the second fact rather than the first to know what it is
    /// operating on.
    let carriesAlphaChannel: Bool

    init(
        orientation: ImageMetadataState,
        declaredOrientation: ExifOrientation?,
        colorProfile: ImageMetadataState,
        alpha: ImageMetadataState,
        carriesAlphaChannel: Bool
    ) {
        self.orientation = orientation
        // A declared orientation outside the valid state would be an orientation the
        // transform could apply without the contract having approved it.
        self.declaredOrientation = orientation == .valid ? declaredOrientation : nil
        self.colorProfile = colorProfile
        self.alpha = alpha
        self.carriesAlphaChannel = carriesAlphaChannel
    }
}

/// Classifies one decoded image's orientation, embedded-profile, and alpha metadata.
enum ImageMetadataInspector {
    /// The four color-space models ColorSync can color-manage into an RGB working
    /// space.
    ///
    /// A profile in one of these is ``ImageMetadataState/valid``. The remaining models
    /// — indexed, pattern, DeviceN, and anything this SDK does not name — describe no
    /// convertible colorimetry, so a profile in one of them is present and parseable
    /// but outside what the contract can work with, which is
    /// ``ImageMetadataState/unsupported``.
    static let convertibleColorSpaceModels: Set<CGColorSpaceModel> = [
        .monochrome, .rgb, .cmyk, .lab, .XYZ,
    ]

    /// Observes the three metadata states from a container's declarations and the
    /// image the decode actually produced.
    ///
    /// `properties` is the Image I/O properties dictionary for the decoded image's
    /// index, read without decoding. `image` is the completely decoded image the
    /// transform will operate on.
    static func observe(
        properties: ImageDeclaredProperties,
        image: CGImage
    ) -> ObservedImageMetadata {
        let orientation = observeOrientation(properties)
        let alpha = observeAlpha(properties, image: image)
        return ObservedImageMetadata(
            orientation: orientation.state,
            declaredOrientation: orientation.declared,
            colorProfile: observeColorProfile(properties, image: image),
            alpha: alpha.state,
            carriesAlphaChannel: alpha.carriesAlphaChannel
        )
    }

    // MARK: Orientation

    /// The orientation state, and the single declared value when there is one.
    ///
    /// Both the normalized top-level declaration and the TIFF sub-dictionary's are
    /// read. Image I/O derives the first from the second, so they normally agree; when
    /// they do not, the container declares two orientations and there is no single
    /// declaration to apply. Choosing one would be a guess, so the state is
    /// ``ImageMetadataState/malformed`` and the contract decides what happens.
    static func observeOrientation(
        _ properties: ImageDeclaredProperties
    ) -> (state: ImageMetadataState, declared: ExifOrientation?) {
        let declarations = [
            properties.orientation,
            properties.tiffOrientation,
        ].compactMap { $0 }

        var values: Set<Int> = []
        for declaration in declarations {
            switch declaration {
            case .integer(let value):
                values.insert(value)
            case .notAnInteger:
                // Present but not a number this adapter can read as an orientation.
                return (.malformed, nil)
            }
        }
        guard let value = values.first else {
            return (.absent, nil)
        }
        guard values.count == 1 else {
            return (.malformed, nil)
        }
        guard let orientation = ExifOrientation(rawValue: value) else {
            return (.unsupported, nil)
        }
        return (.valid, orientation)
    }

    // MARK: Embedded color profile

    /// The embedded-color-profile state.
    ///
    /// The container's declaration decides first, because Core Graphics assigns a
    /// working assumption to every decoded image — an untagged PNG decodes into sRGB —
    /// and that assumption is not an embedded profile. When Image I/O reports no
    /// profile name there is nothing embedded to act on, which is
    /// ``ImageMetadataState/absent``.
    ///
    /// That also covers a profile Image I/O itself rejected: a PNG whose `iCCP` chunk
    /// does not parse reaches this adapter with no profile name at all, so it is
    /// observed as absent rather than malformed. ``ImageMetadataState/malformed`` is
    /// reserved for a declaration that reaches the adapter and is unusable here — a
    /// non-string profile name, or a declared profile whose decode produced no color
    /// space to convert from.
    static func observeColorProfile(
        _ properties: ImageDeclaredProperties,
        image: CGImage
    ) -> ImageMetadataState {
        colorProfileState(
            profileName: properties.profileName,
            decodedColorSpaceModel: image.colorSpace?.model
        )
    }

    /// The embedded-color-profile state, from the two facts that decide it.
    ///
    /// Split out from ``observeColorProfile(_:image:)`` so the malformed branch is
    /// reachable in a test: it needs a decoded image carrying no colorimetry at all,
    /// which is not a thing any encoder on a development host will produce from a
    /// supported container.
    ///
    /// `decodedColorSpaceModel` is `nil` when the decode carries no color space.
    static func colorProfileState(
        profileName: DeclaredText?,
        decodedColorSpaceModel: CGColorSpaceModel?
    ) -> ImageMetadataState {
        guard let profileName else {
            return .absent
        }
        switch profileName {
        case .notANonEmptyString:
            return .malformed
        case .text:
            guard let model = decodedColorSpaceModel else {
                // A declared profile whose decode carries no colorimetry at all. There
                // is no space to convert from and none to assign into, so the
                // declaration is not usable.
                return .malformed
            }
            guard convertibleColorSpaceModels.contains(model) else {
                return .unsupported
            }
            return .valid
        }
    }

    // MARK: Alpha

    /// The alpha state, and whether the decode carries an alpha channel.
    ///
    /// The decode is authoritative about whether there is an alpha channel, because
    /// that is the channel an alpha action operates on. The container's declaration is
    /// consulted in one direction only: a container claiming transparency that the
    /// decode did not produce is ``ImageMetadataState/malformed``, because the
    /// contract's alpha action would otherwise be applied to a channel that does not
    /// exist and the result would be indistinguishable from an opaque image. The
    /// opposite disagreement is not treated the same way: when the decode does carry
    /// alpha, the channel the action operates on is present and its existence is not in
    /// doubt.
    ///
    /// That disagreement is in fact the only route to ``ImageMetadataState/malformed``
    /// here. An arrangement this build cannot name is read successfully and simply names
    /// no channel layout the contract's actions describe, which is
    /// ``ImageMetadataState/unsupported``.
    static func observeAlpha(
        _ properties: ImageDeclaredProperties,
        image: CGImage
    ) -> (state: ImageMetadataState, carriesAlphaChannel: Bool) {
        alphaState(
            alphaInfoRawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue,
            declaresAlpha: properties.declaresAlpha
        )
    }

    /// The alpha state, from the two facts that decide it.
    ///
    /// Split out from ``observeAlpha(_:image:)`` for the same reason as the profile rule:
    /// an alpha arrangement this build does not name cannot be put into a `CGImage`, so
    /// that branch is only reachable by stating the code directly.
    static func alphaState(
        alphaInfoRawValue: UInt32,
        declaresAlpha: Bool?
    ) -> (state: ImageMetadataState, carriesAlphaChannel: Bool) {
        guard let alphaInfo = CGImageAlphaInfo(rawValue: alphaInfoRawValue) else {
            // An alpha code this SDK does not assign. Read successfully, names no channel
            // arrangement the contract's actions describe, so it is the unsupported state
            // rather than the malformed one — the same answer as the `@unknown default`
            // below, because they are the same situation reached two ways.
            return (.unsupported, false)
        }
        switch alphaInfo {
        case .alphaOnly:
            // Alpha with no color channels. There is no RGB to composite or to keep, so
            // the state is outside what the contract's actions describe.
            return (.unsupported, true)
        case .none, .noneSkipFirst, .noneSkipLast:
            if declaresAlpha == true {
                return (.malformed, false)
            }
            return (.absent, false)
        case .premultipliedFirst, .premultipliedLast, .first, .last:
            return (.valid, true)
        @unknown default:
            // An arrangement added after this build was compiled. Not one whose alpha
            // channel this build can locate, so it reports no identifiable channel rather
            // than guessing at one.
            return (.unsupported, false)
        }
    }
}

// MARK: - Declared properties

/// One value a container declared, as far as this adapter could read it.
///
/// The point of the enum is that "absent" and "present but unreadable" are different
/// states in Requirement 3.7 and collapsing them into `nil` would make one of them
/// unreachable.
enum DeclaredInteger: Hashable, Sendable {
    case integer(Int)
    /// Present, but not a value this adapter can read as an integer.
    case notAnInteger
}

/// One declared text value, as far as this adapter could read it.
enum DeclaredText: Hashable, Sendable {
    case text(String)
    /// Present, but not a non-empty string.
    case notANonEmptyString
}

/// The subset of a container's Image I/O declarations the contract's metadata rules
/// are decided from.
///
/// A value type rather than the raw dictionary so the classification rules are a pure
/// function of named, `Sendable` evidence: the malformed and unsupported branches can
/// then be constructed directly in a test, which is the only way to reach several of
/// them on a host whose encoders normalize the declaration while writing it.
struct ImageDeclaredProperties: Hashable, Sendable {
    /// The normalized top-level orientation declaration.
    let orientation: DeclaredInteger?

    /// The TIFF sub-dictionary's orientation declaration.
    let tiffOrientation: DeclaredInteger?

    /// The embedded profile's name.
    let profileName: DeclaredText?

    /// The container's own claim about transparency, when it makes one.
    let declaresAlpha: Bool?

    init(
        orientation: DeclaredInteger? = nil,
        tiffOrientation: DeclaredInteger? = nil,
        profileName: DeclaredText? = nil,
        declaresAlpha: Bool? = nil
    ) {
        self.orientation = orientation
        self.tiffOrientation = tiffOrientation
        self.profileName = profileName
        self.declaresAlpha = declaresAlpha
    }

    /// Reads the declarations out of one Image I/O properties dictionary.
    ///
    /// Nothing is inferred: a key that is not present stays `nil`, and a key whose
    /// value is not of the expected kind becomes the explicit "present but unreadable"
    /// case rather than being dropped.
    init(imageIOProperties properties: [CFString: Any]) {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        self.init(
            orientation: Self.declaredInteger(properties[kCGImagePropertyOrientation]),
            tiffOrientation: Self.declaredInteger(tiff?[kCGImagePropertyTIFFOrientation]),
            profileName: Self.declaredText(properties[kCGImagePropertyProfileName]),
            declaresAlpha: Self.declaredBool(properties[kCGImagePropertyHasAlpha])
        )
    }

    /// An integer declaration, or the unreadable case, or `nil` when absent.
    ///
    /// Image I/O hands back `CFNumber`s that may carry a floating-point value. A
    /// non-integral or unrepresentable number is not read as an integer: rounding it
    /// would invent an orientation the container never declared.
    private static func declaredInteger(_ value: Any?) -> DeclaredInteger? {
        guard let value else { return nil }
        guard let number = value as? NSNumber else { return .notAnInteger }
        let magnitude = number.doubleValue
        guard magnitude.isFinite,
              magnitude == magnitude.rounded(),
              magnitude >= Double(Int32.min),
              magnitude <= Double(Int32.max)
        else {
            return .notAnInteger
        }
        return .integer(number.intValue)
    }

    /// A text declaration, or the unreadable case, or `nil` when absent.
    private static func declaredText(_ value: Any?) -> DeclaredText? {
        guard let value else { return nil }
        guard let text = value as? String, !text.isEmpty else { return .notANonEmptyString }
        return .text(text)
    }

    /// A boolean declaration, or `nil` when absent or unreadable.
    ///
    /// Unlike the other two this collapses "absent" and "unreadable", because the only
    /// thing the alpha rule does with it is act on an affirmative claim of
    /// transparency; an unreadable value is not such a claim.
    private static func declaredBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        return number.boolValue
    }
}
