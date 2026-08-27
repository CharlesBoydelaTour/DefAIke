import DefAIkeDomain
import CoreGraphics
import CryptoKit
import Foundation

// Turning the contract's named working color space into an actual ColorSync space.
//
// Requirement 4.3 requires the decode to produce three-channel RGB "according to the
// bound contract", and the design's reason for naming the space at all is that a
// device-parity failure should point at one color space rather than at whatever Core
// Graphics happened to choose. So the name has to resolve to exactly one space, and a
// name this build cannot resolve has to fail rather than resolve to something close.
//
// The table below is the whole of the resolution. It is closed, and that is the point:
// an identifier outside it returns `nil`, which the transform reports as
// `preprocessing-error`. There is no substring match, no case-insensitive comparison,
// and no "nearest available space", because each of those would let a signed contract
// silently select a different colorimetry than the one it names and every parity
// measurement taken against it would still look fine.
//
// Extended-range spaces are deliberately absent from the table even though Core
// Graphics provides them. Their whole purpose is component values outside [0, 1], and
// the contract's model input is unsigned 8-bit (``ModelInputContract``), so reaching one
// would mean clamping — an implicit fallback that changes pixels. A contract naming one
// fails closed instead.

/// The contract's working color space, resolved.
///
/// Not `Sendable`: `CGColorSpace` is a Core Foundation object and this value stays
/// inside one preprocessing call, like every other framework handle in this module.
struct WorkingColorSpace {
    /// The identifier the contract named, retained for diagnostics.
    let identifier: String

    /// The resolved space. Always a three-channel RGB space.
    let colorSpace: CGColorSpace

    /// The identifiers a contract may name, and the Core Graphics space each selects.
    ///
    /// An enum rather than a dictionary so the identifier set and the resolution are one
    /// declaration the compiler keeps exhaustive, instead of two that can drift apart and
    /// leave an accepted identifier with no space or a space with no way to name it.
    ///
    /// The raw values are the Core Graphics constant names rather than human profile
    /// descriptions ("Display P3") because a description is neither unique nor stable
    /// under localization, and a working space selected by a localized string is a
    /// working space that can change with the device's language.
    enum Identifier: String, Hashable, Sendable, CaseIterable {
        case sRGB = "kCGColorSpaceSRGB"
        case linearSRGB = "kCGColorSpaceLinearSRGB"
        case displayP3 = "kCGColorSpaceDisplayP3"
        case adobeRGB1998 = "kCGColorSpaceAdobeRGB1998"
        case genericRGBLinear = "kCGColorSpaceGenericRGBLinear"
        case itur709 = "kCGColorSpaceITUR_709"
        case itur2020 = "kCGColorSpaceITUR_2020"
        case dciP3 = "kCGColorSpaceDCIP3"
        case rommRGB = "kCGColorSpaceROMMRGB"

        /// The Core Graphics name this identifier selects.
        var coreGraphicsName: CFString {
            switch self {
            case .sRGB: CGColorSpace.sRGB
            case .linearSRGB: CGColorSpace.linearSRGB
            case .displayP3: CGColorSpace.displayP3
            case .adobeRGB1998: CGColorSpace.adobeRGB1998
            case .genericRGBLinear: CGColorSpace.genericRGBLinear
            case .itur709: CGColorSpace.itur_709
            case .itur2020: CGColorSpace.itur_2020
            case .dciP3: CGColorSpace.dcip3
            case .rommRGB: CGColorSpace.rommrgb
            }
        }
    }

    /// Number of color components a working space must have.
    ///
    /// Three, because the contract's channel order is RGB and its model input carries
    /// three channels (Requirements 4.3 and 4.6). A space with any other component
    /// count cannot be the space those bytes are in.
    static let requiredComponentCount = 3

    /// Resolves `descriptor`, or throws when it cannot be resolved exactly.
    ///
    /// Three separate refusals, because they are three different mistakes: a name this
    /// build does not know, a name that resolves to something that is not three-channel
    /// RGB, and a name that resolves but to different ICC bytes than the contract binds.
    static func resolve(
        _ descriptor: ColorSpaceDescriptor
    ) throws(PreprocessingFailure) -> WorkingColorSpace {
        let identifier = descriptor.identifier.value
        guard let name = Identifier(rawValue: identifier),
              let colorSpace = CGColorSpace(name: name.coreGraphicsName)
        else {
            throw .workingColorSpaceUnavailable(identifier: identifier)
        }
        guard colorSpace.model == .rgb,
              colorSpace.numberOfComponents == requiredComponentCount
        else {
            throw .workingColorSpaceNotThreeChannelRGB(identifier: identifier)
        }
        if let boundDigest = descriptor.profileDigest {
            guard matchesProfile(colorSpace, digest: boundDigest) else {
                throw .workingColorSpaceProfileMismatch(identifier: identifier)
            }
        }
        return WorkingColorSpace(identifier: identifier, colorSpace: colorSpace)
    }

    /// Whether `colorSpace` carries exactly the ICC bytes `digest` names.
    ///
    /// A bound digest is the contract pinning the working space to exact profile bytes,
    /// so a space whose ICC data is absent or hashes differently is not the space the
    /// contract named — even when its identifier matches. The comparison is over the
    /// full digest, and a space that carries no ICC data at all does not pass: "no bytes
    /// to compare" is not agreement.
    ///
    /// System color spaces are stable within an OS version but are not contractually
    /// frozen across them, which is exactly why a release that needs byte-exact
    /// colorimetry binds the digest and gets a fail-closed refusal when the platform
    /// changes underneath it, rather than a silent shift in every sample handed to the
    /// model.
    static func matchesProfile(
        _ colorSpace: CGColorSpace,
        digest bound: DefAIkeDomain.SHA256Digest
    ) -> Bool {
        guard let iccData = colorSpace.copyICCData() as Data? else { return false }
        let computed = Array(CryptoKit.SHA256.hash(data: iccData))
        guard let digest = DefAIkeDomain.SHA256Digest(bytes: computed) else { return false }
        return digest == bound
    }
}
