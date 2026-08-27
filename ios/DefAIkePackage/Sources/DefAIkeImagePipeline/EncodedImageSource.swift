import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The Image I/O reader, wrapped so each step is a named operation with an explicit
// cost.
//
// The ordering the requirements impose is the reason this is a type rather than a
// sequence of free calls: reading the container type, the frame count, and the
// declared dimensions must all be possible *before* a full-resolution decode
// allocates anything (Requirement 3.4 and the design's "declared dimensions and byte
// count are checked before allocation"). Every read here is metadata-only except
// ``decodeCompleteImage(at:)``, which is the single allocating call.
//
// The type is deliberately not `Sendable`: `CGImageSource` is a mutable
// Core Foundation object and stays inside one adapter call.

/// What a container declares about one of its images, before any pixels are decoded.
struct DeclaredImageProperties: Hashable, Sendable {
    /// Declared pixel width. Positive and representable as an `Int`.
    let width: Int

    /// Declared pixel height. Positive and representable as an `Int`.
    let height: Int

    /// Declared bits per component, when the container states it.
    ///
    /// Used only to bound the decoded allocation from above: a 16-bit-per-component
    /// source decodes into twice the memory an 8-bit one does, so assuming 8 would
    /// under-count exactly the input that most needs the check.
    let bitsPerComponent: Int?
}

/// One Image I/O reader over the retained encoded bytes.
final class EncodedImageSource {
    /// Widest per-pixel decode this adapter can receive from Image I/O.
    ///
    /// Core Graphics decodes into at most four channels, so the byte cost of one
    /// decoded pixel is bounded by `channels * bytesPerComponent`. This is a
    /// structural property of the decode formats, not an approved resource value: the
    /// approved ceiling is the bound Resource Budget, and this constant only makes the
    /// pre-decode estimate an over-estimate rather than an under-estimate.
    static let maximumDecodedChannelCount: UInt64 = 4

    private let source: CGImageSource

    /// Creates a reader, or `nil` when Image I/O cannot open the bytes at all.
    init?(bytes: [UInt8]) {
        let data = Data(bytes)
        // Caching is off for every metadata read: nothing here should populate a
        // decoded-image cache before the resource checks have run.
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        self.source = source
    }

    /// The container type Image I/O read from the content, or `nil` when it could not
    /// establish one.
    var contentType: UTType? {
        guard let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(identifier)
    }

    /// The number of images the container actually holds.
    ///
    /// This is the design's animation signal. It is zero for a container whose type
    /// was recognized but whose image data is truncated away.
    var frameCount: Int { CGImageSourceGetCount(source) }

    /// What the container declares about the image at `index`, or `nil` when the
    /// declaration is absent, non-numeric, non-positive, or not representable.
    ///
    /// A container that cannot state a usable dimension is malformed; it is not
    /// repaired with a guess and it is not allowed to reach a resource comparison
    /// with an invented value.
    func declaredProperties(at index: Int) -> DeclaredImageProperties? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                options as CFDictionary
            ) as? [CFString: Any],
            let width = Self.positiveInteger(properties[kCGImagePropertyPixelWidth]),
            let height = Self.positiveInteger(properties[kCGImagePropertyPixelHeight])
        else {
            return nil
        }
        return DeclaredImageProperties(
            width: width,
            height: height,
            bitsPerComponent: Self.positiveInteger(properties[kCGImagePropertyDepth])
        )
    }

    /// The declarations the contract's metadata rules are decided from, read without
    /// decoding.
    ///
    /// Separate from ``declaredProperties(at:)``, which reads only what the pre-decode
    /// resource checks need. This one reads the orientation, embedded-profile, and alpha
    /// declarations, and it exists because the decoded `CGImage` alone cannot supply
    /// them: Core Graphics assigns every decoded image some color space and some alpha
    /// layout, so "the container declared nothing" is not recoverable after the decode
    /// (Requirement 3.7's absent state).
    ///
    /// An unreadable properties dictionary yields an empty declaration set rather than a
    /// failure. That is not a fallback: no declaration is exactly the ``absent`` state
    /// for all three fields, and the contract decides what happens in it.
    func metadataDeclarations(at index: Int) -> ImageDeclaredProperties {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                options as CFDictionary
            ) as? [CFString: Any]
        else {
            return ImageDeclaredProperties()
        }
        return ImageDeclaredProperties(imageIOProperties: properties)
    }

    /// Decodes the image at `index` completely, or returns `nil`.
    ///
    /// `kCGImageSourceShouldCacheImmediately` is what makes this a complete decode
    /// rather than a promise of one: without it Core Graphics defers the pixel work
    /// to the first draw, and a truncated container would fail inside preprocessing
    /// or, worse, produce partial pixels that reached inference. Requirement 3.1
    /// requires all image data the bound contract needs to be decoded before pixel
    /// inference begins, so the work happens here and its failure is
    /// `decoding-error`.
    func decodeCompleteImage(at index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            // No floating-point decode: the contract's model input is unsigned 8-bit
            // RGB, and a float decode would change both the memory cost and the
            // sample values parity is measured against.
            kCGImageSourceShouldAllowFloat: false,
        ]
        return CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary)
    }

    /// A positive `Int` from an Image I/O property value, or `nil`.
    ///
    /// Image I/O hands back `CFNumber`s that may hold a floating-point or 64-bit
    /// value. The magnitude is checked before conversion so an out-of-range
    /// declaration becomes "no usable declaration" instead of a wrapped or clamped
    /// number that would then be compared against a budget.
    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let magnitude = number.doubleValue
        guard magnitude.isFinite, magnitude >= 1, magnitude <= Double(Int64.max) else { return nil }
        let integer = number.int64Value
        guard integer >= 1, let representable = Int(exactly: integer) else { return nil }
        return representable
    }
}
