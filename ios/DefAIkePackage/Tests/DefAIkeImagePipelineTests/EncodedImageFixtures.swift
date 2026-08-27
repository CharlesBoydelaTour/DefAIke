import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Real encoded containers, produced by Image I/O at test time.
//
// These are not the Release Fixture Suite. That suite is immutable, versioned, and
// carries approved expected outputs (task 14.1), and nothing here may be substituted
// for it. What these bytes are for is the classification and decode behavior of task
// 5.1: a JPEG has to be a real JPEG for content sniffing to mean anything, and a
// truncated JPEG has to be a real JPEG with its tail removed for `decoding-error` to
// mean anything.
//
// The synthetic media headers are deliberately headers only. Requirement 1.11 is about
// recognizing video and audio *before* any decode, so the classifier has to reach its
// answer from the leading bytes, and a header with nothing behind it proves it did.

enum EncodedImageFixture {
    /// Whether this host can encode `type`. HEIF has no Image I/O encoder even where
    /// HEIC does, so a HEIF assertion is skipped rather than made against a fake.
    static func canEncode(_ type: UTType) -> Bool {
        let sink = NSMutableData()
        return CGImageDestinationCreateWithData(sink, type.identifier as CFString, 1, nil) != nil
    }

    /// A deterministic RGB gradient. Content that survives JPEG without being flat, so
    /// a truncated copy actually loses image data.
    static func gradient(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x * 255) / max(width - 1, 1))
                pixels[offset + 1] = UInt8((y * 255) / max(height - 1, 1))
                pixels[offset + 2] = UInt8((x ^ y) & 0xFF)
                pixels[offset + 3] = 0xFF
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// A single-frame grayscale image, so a non-RGB decode path is covered.
    static func grayscale(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in pixels.indices {
            pixels[index] = UInt8(index % 256)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Encodes `image` `frameCount` times into `type`, or `nil` when the host has no
    /// encoder for it.
    static func encode(
        _ image: CGImage,
        as type: UTType,
        frameCount: Int = 1
    ) -> [UInt8]? {
        let sink = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            sink,
            type.identifier as CFString,
            frameCount,
            nil
        ) else {
            return nil
        }
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return [UInt8](sink as Data)
    }

    /// A supported single-frame container, 40 by 24 pixels.
    static func supported(_ type: UTType) -> [UInt8]? {
        encode(gradient(width: 40, height: 24), as: type)
    }

    /// The leading `fraction` of a real JPEG: a container whose type is intact and
    /// whose image data is not.
    static func truncatedJPEG(fraction: Double) -> [UInt8] {
        guard let jpeg = supported(.jpeg) else {
            preconditionFailure("this host cannot encode JPEG")
        }
        let keep = max(1, Int(Double(jpeg.count) * fraction))
        return Array(jpeg.prefix(keep))
    }

    // MARK: - Synthetic non-image containers

    /// An ISO base media header carrying `brand`, with no payload.
    static func isoBaseMedia(brand: String) -> [UInt8] {
        precondition(brand.utf8.count == 4, "an ISO base media brand is four characters")
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
        bytes.append(contentsOf: Array("ftyp".utf8))
        bytes.append(contentsOf: Array(brand.utf8))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return bytes
    }

    /// A RIFF header carrying `formType`, with no payload.
    static func riff(formType: String) -> [UInt8] {
        precondition(formType.utf8.count == 4, "a RIFF form type is four characters")
        var bytes = Array("RIFF".utf8)
        bytes.append(contentsOf: [0x24, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: Array(formType.utf8))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 24))
        return bytes
    }

    /// An MP3 frame header with no frames behind it.
    static let mp3Header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 28)

    /// An ID3-tagged audio header.
    static let id3Header: [UInt8] = Array("ID3".utf8) + [0x03, 0x00, 0x00]
        + [UInt8](repeating: 0, count: 26)

    /// A Matroska/WebM EBML header.
    static let ebmlHeader: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 28)

    /// A one-page PDF that Image I/O opens and reports a page count for.
    static func pdf() -> [UInt8] {
        let sink = NSMutableData()
        guard let consumer = CGDataConsumer(data: sink) else {
            preconditionFailure("could not create a PDF consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 40, height: 24)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            preconditionFailure("could not create a PDF context")
        }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return [UInt8](sink as Data)
    }

    /// Bytes matching no signature and no Image I/O container.
    static let unidentifiableBytes: [UInt8] = Array("this is not an image at all".utf8)
}
