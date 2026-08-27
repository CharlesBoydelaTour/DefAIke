import DefAIkeDomain
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

// Inputs for the contract-total metadata, RGB, color, and alpha transform.
//
// **Nothing here is the Release Fixture Suite.** That suite is immutable, versioned, and
// carries approved expected outputs (task 14.1). These are constructed at test time so a
// specific *observable condition* can be produced on demand: a container that declares no
// embedded profile at all, a source tagged Display P3, a source whose alpha is stored
// unpremultiplied.
//
// Two kinds of input, for two different reasons:
//
//   * Encoded bytes, for the observation rules. Whether a container declares an
//     orientation or a profile name is a fact about the container, and only a real
//     container establishes it.
//   * Directly constructed `CGImage`s, for the transform. The transform's behavior
//     depends on the decoded source's color space and alpha layout, and building the
//     image directly is the only way to cover layouts an encoder on this host will not
//     produce — a premultiplied source, an alpha-first packing, a 16-bit source.
//
// The hand-built PNG writer exists for one condition nothing else reaches: Image I/O's
// PNG *encoder* always writes a color profile, so every PNG this host encodes declares
// one. A PNG assembled byte by byte with no `iCCP`, `sRGB`, or `gAMA` chunk is the only
// way to get the absent embedded-profile state from a real container.

// MARK: - Hand-assembled PNG

/// A PNG built chunk by chunk, so its declarations are exactly the ones stated.
enum RawPNG {
    /// PNG color types this writer emits.
    enum ColorType: UInt8 {
        case grayscale = 0
        case truecolor = 2
        case truecolorAlpha = 6

        var channelCount: Int {
            switch self {
            case .grayscale: 1
            case .truecolor: 3
            case .truecolorAlpha: 4
            }
        }
    }

    /// A PNG with no color-management chunk of any kind.
    ///
    /// The deterministic sample pattern matters only in that it is not flat: a constant
    /// image would hide a color conversion, a reflection, and a rotation all at once.
    static func withoutColorChunks(
        width: Int,
        height: Int,
        colorType: ColorType = .truecolor,
        bitDepth: UInt8 = 8
    ) -> [UInt8] {
        build(width: width, height: height, colorType: colorType, bitDepth: bitDepth)
    }

    /// A PNG carrying an `sRGB` chunk, so Image I/O reports a profile name.
    static func withSRGBChunk(width: Int, height: Int) -> [UInt8] {
        build(
            width: width,
            height: height,
            colorType: .truecolor,
            bitDepth: 8,
            extraChunks: [chunk("sRGB", [0])]
        )
    }

    private static func build(
        width: Int,
        height: Int,
        colorType: ColorType,
        bitDepth: UInt8,
        extraChunks: [[UInt8]] = []
    ) -> [UInt8] {
        precondition(bitDepth == 8 || bitDepth == 16, "this writer emits 8- or 16-bit samples")
        let bytesPerSample = Int(bitDepth) / 8
        var raw: [UInt8] = []
        for y in 0..<height {
            // Filter type 0: no filtering, so the sample bytes are literal.
            raw.append(0)
            for x in 0..<width {
                for channel in 0..<colorType.channelCount {
                    let value = UInt8((x * 37 + y * 11 + channel * 53) & 0xFF)
                    raw.append(value)
                    if bytesPerSample == 2 { raw.append(255 - value) }
                }
            }
        }
        var header = bigEndian(UInt32(width)) + bigEndian(UInt32(height))
        header += [bitDepth, colorType.rawValue, 0, 0, 0]
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", header)
        for extra in extraChunks { png += extra }
        png += chunk("IDAT", storedDeflate(raw))
        png += chunk("IEND", [])
        return png
    }

    private static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + payload
        return bigEndian(UInt32(payload.count)) + typed + bigEndian(crc32(typed))
    }

    /// A zlib stream of stored (uncompressed) deflate blocks.
    ///
    /// Stored blocks keep the writer to arithmetic that can be read and checked, rather
    /// than depending on a compressor whose output would have to be trusted.
    private static func storedDeflate(_ raw: [UInt8]) -> [UInt8] {
        var stream: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let length = min(65535, raw.count - offset)
            let isFinal: UInt8 = offset + length >= raw.count ? 1 : 0
            stream.append(isFinal)
            stream.append(UInt8(length & 0xFF))
            stream.append(UInt8(length >> 8 & 0xFF))
            let complement = UInt16(length) ^ 0xFFFF
            stream.append(UInt8(complement & 0xFF))
            stream.append(UInt8(complement >> 8 & 0xFF))
            stream += Array(raw[offset..<(offset + length)])
            offset += length
        } while offset < raw.count
        return stream + bigEndian(adler32(raw))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
        ]
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var remainder: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            remainder ^= UInt32(byte)
            for _ in 0..<8 {
                remainder = remainder & 1 != 0 ? 0xEDB8_8320 ^ (remainder >> 1) : remainder >> 1
            }
        }
        return remainder ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in bytes {
            low = (low + UInt32(byte)) % 65521
            high = (high + low) % 65521
        }
        return high << 16 | low
    }
}

// MARK: - Encoded containers with stated declarations

enum DeclaringImageFixture {
    /// Encodes `image` into `type` with exactly `properties` declared.
    static func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any]
    ) -> [UInt8]? {
        let sink = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            sink,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return [UInt8](sink as Data)
    }

    /// A JPEG declaring TIFF/EXIF orientation `value`.
    static func jpeg(orientation value: Int, width: Int = 8, height: Int = 6) -> [UInt8]? {
        encode(
            EncodedImageFixture.gradient(width: width, height: height),
            as: .jpeg,
            properties: [kCGImagePropertyOrientation: value]
        )
    }

    /// The declarations Image I/O reports for `bytes`, read without decoding.
    static func declarations(of bytes: [UInt8]) -> ImageDeclaredProperties? {
        EncodedImageSource(bytes: bytes)?.metadataDeclarations(at: 0)
    }

    /// The completely decoded first image of `bytes`.
    static func decode(_ bytes: [UInt8]) -> CGImage? {
        EncodedImageSource(bytes: bytes)?.decodeCompleteImage(at: 0)
    }
}

// MARK: - Directly constructed decoded sources

/// One decoded source image with an exactly stated color space and alpha layout.
enum SourceImageFixture {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let genericGray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    /// A 32-bit-per-pixel image over `pixels`, exactly as given.
    ///
    /// No encoder is involved, so the samples the transform reads are the samples written
    /// here and a byte-level assertion means something.
    static func interleaved32(
        width: Int,
        height: Int,
        pixels: [UInt8],
        space: CGColorSpace = sRGB,
        alpha: CGImageAlphaInfo = .noneSkipLast
    ) -> CGImage {
        precondition(pixels.count == width * height * 4, "a 32-bit image needs four bytes a pixel")
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            preconditionFailure("Core Graphics refused a \(width)x\(height) 32-bit image")
        }
        return image
    }

    /// A single-channel grayscale image, whose colorimetry cannot be relabelled as RGB.
    static func grayscale(width: Int, height: Int) -> CGImage {
        var samples = [UInt8](repeating: 0, count: width * height)
        for index in samples.indices { samples[index] = UInt8((index * 40) % 256) }
        guard let provider = CGDataProvider(data: Data(samples) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  space: genericGray,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            preconditionFailure("Core Graphics refused a \(width)x\(height) grayscale image")
        }
        return image
    }

    /// Distinct opaque pixels, so a permutation is detectable pixel by pixel.
    ///
    /// Each pixel's red channel encodes its column and its green channel its row, which
    /// makes an assertion about where a pixel ended up readable rather than a comparison
    /// against a blob.
    static func addressablePixels(width: Int, height: Int) -> [UInt8] {
        precondition(width <= 250 && height <= 250, "the address encoding needs small edges")
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x + 1)
                pixels[offset + 1] = UInt8(y + 1)
                pixels[offset + 2] = UInt8((x * 7 + y * 13) % 251)
                pixels[offset + 3] = 0
            }
        }
        return pixels
    }
}

// MARK: - Decoded-image handles

enum DecodedImageFixture {
    /// A ``DecodedImage`` over `image`, measured the way the validator measures one.
    static func of(
        _ image: CGImage,
        sessionID: AnalysisSessionID = Fixture.sessionID()
    ) -> DecodedImage {
        guard let dimensions = PixelDimensions(width: image.width, height: image.height) else {
            preconditionFailure("a decoded fixture must have positive dimensions")
        }
        return DecodedImage(
            sessionID: sessionID,
            dimensions: dimensions,
            decodedByteCount: UInt64(image.bytesPerRow) * UInt64(image.height),
            image: image
        )
    }
}

// MARK: - Independent orientation reference

/// Where each stored pixel belongs in the displayed image, per TIFF tag 274.
///
/// Written from the EXIF specification's own wording — each value names where the stored
/// image's first row and first column go — and deliberately *not* derived from
/// ``ExifOrientation/steps``. It is the independent side of the comparison: if the step
/// table and this mapping ever agree only because one was copied from the other, the test
/// proves nothing.
enum OrientationReference {
    /// The displayed coordinate of stored pixel `(x, y)` in a `width` by `height` image.
    static func displayedCoordinate(
        _ orientation: ExifOrientation,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> (x: Int, y: Int) {
        switch orientation {
        case .topLeft: (x, y)
        case .topRight: (width - 1 - x, y)
        case .bottomRight: (width - 1 - x, height - 1 - y)
        case .bottomLeft: (x, height - 1 - y)
        case .leftTop: (y, x)
        case .rightTop: (height - 1 - y, x)
        case .rightBottom: (height - 1 - y, width - 1 - x)
        case .leftBottom: (y, width - 1 - x)
        }
    }

    /// The displayed size of a `width` by `height` image under `orientation`.
    static func displayedSize(
        _ orientation: ExifOrientation,
        width: Int,
        height: Int
    ) -> (width: Int, height: Int) {
        switch orientation {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: (width, height)
        case .leftTop, .rightTop, .rightBottom, .leftBottom: (height, width)
        }
    }
}

// MARK: - Reading a rendered surface

extension PixelSurface {
    /// The three-channel pixel at `(x, y)`, read from the packed bytes.
    func rgb(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        precondition(channelCount == 3, "this reader is for a rendered three-channel surface")
        let bytes = copyPackedBytes()
        let offset = (y * width + x) * 3
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}
