import UniformTypeIdentifiers

// Content sniffing from the leading bytes.
//
// A provider's declared type identifier is attacker-influenced and is never trusted
// (``ContentTypeHint`` says so at the domain boundary, and the design says Image I/O
// reads the actual container type). Image I/O is the authority for anything it can
// read, but it reads only image and PDF containers: a movie or an audio file is
// simply "no source" to it, which would make a QuickTime file indistinguishable from
// random bytes. Requirement 1.11 needs those distinguished, so this file adds the one
// thing Image I/O cannot supply: a content signature table for the video and audio
// families, plus the ISO base media brands that separate a HEIF still image from an
// MP4 movie sharing the same box structure.
//
// The table names a Uniform Type Identifier wherever the system declares one, and the
// resulting family is taken from that type's declared conformance rather than from a
// second hand-written mapping. A signature whose identifier the system does not
// declare still classifies, using the family recorded with the signature.

/// The broad family a content signature belongs to.
public enum SniffedContentFamily: String, Hashable, Sendable {
    /// A still-image container.
    case stillImage
    /// Video, or a movie container that may also carry audio.
    case audiovisual
    /// Audio only.
    case audio
    /// An identified static container that is not an image: a PDF, for example.
    case otherStaticContainer
}

/// What the leading bytes say the content is.
public struct SniffedContentType: Hashable, Sendable {
    /// The Uniform Type Identifier the signature names.
    public let identifier: String

    /// The system-declared type, when the system declares this identifier.
    public let type: UTType?

    /// The family, taken from the declared type's conformance when the system
    /// declares it and from the signature table otherwise.
    public let family: SniffedContentFamily

    fileprivate init(identifier: String, tabulatedFamily: SniffedContentFamily) {
        self.identifier = identifier
        let type = UTType(identifier)
        self.type = type
        self.family = type.flatMap(SniffedContentFamily.init(declaring:)) ?? tabulatedFamily
    }
}

extension SniffedContentFamily {
    /// The family a system-declared type belongs to, or `nil` when its conformance
    /// does not place it in one.
    ///
    /// Checked most specific first: `public.video` conforms to `public.movie`, and
    /// several audio types conform to `public.audiovisual-content` without being
    /// movies, so audio is decided before the movie check.
    init?(declaring type: UTType) {
        if type.conforms(to: .audio) {
            self = .audio
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .audiovisual
        } else if type.conforms(to: .image) {
            self = .stillImage
        } else {
            return nil
        }
    }
}

/// Sniffs the actual content family from the leading bytes of a container.
public enum ContentSignature {
    /// Bytes examined. Every signature below decides inside this window, so a
    /// classification never depends on holding the whole encoded input.
    public static let inspectedPrefixLength = 32

    /// The content type the leading bytes identify, or `nil` when no signature
    /// matches.
    ///
    /// `nil` is not "malformed": Image I/O may still recognize the container, and
    /// the classifier consults it. It only means this table has nothing to add.
    public static func sniff(_ bytes: some Collection<UInt8>) -> SniffedContentType? {
        let window = Array(bytes.prefix(inspectedPrefixLength))

        if window.starts(with: [0xFF, 0xD8, 0xFF]) {
            return SniffedContentType(identifier: "public.jpeg", tabulatedFamily: .stillImage)
        }
        if window.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return SniffedContentType(identifier: "public.png", tabulatedFamily: .stillImage)
        }
        if ascii(window, at: 0, count: 4) == "GIF8" {
            return SniffedContentType(
                identifier: "com.compuserve.gif",
                tabulatedFamily: .stillImage
            )
        }
        if window.starts(with: [0x49, 0x49, 0x2A, 0x00]) || window.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return SniffedContentType(identifier: "public.tiff", tabulatedFamily: .stillImage)
        }
        if window.starts(with: [0x42, 0x4D]), window.count >= 14 {
            return SniffedContentType(
                identifier: "com.microsoft.bmp",
                tabulatedFamily: .stillImage
            )
        }
        if ascii(window, at: 0, count: 5) == "%PDF-" {
            return SniffedContentType(
                identifier: "com.adobe.pdf",
                tabulatedFamily: .otherStaticContainer
            )
        }
        if window.starts(with: [0x38, 0x42, 0x50, 0x53]) {
            return SniffedContentType(
                identifier: "com.adobe.photoshop-image",
                tabulatedFamily: .stillImage
            )
        }
        if window.starts(with: [0x00, 0x00, 0x00, 0x0C]), ascii(window, at: 4, count: 4) == "jP  " {
            return SniffedContentType(
                identifier: "public.jpeg-2000",
                tabulatedFamily: .stillImage
            )
        }
        if window.starts(with: [0xFF, 0x4F, 0xFF, 0x51]) {
            return SniffedContentType(
                identifier: "public.jpeg-2000",
                tabulatedFamily: .stillImage
            )
        }
        if window.starts(with: [0x76, 0x2F, 0x31, 0x01]) {
            return SniffedContentType(
                identifier: "com.ilm.openexr-image",
                tabulatedFamily: .stillImage
            )
        }
        if let riff = riffSignature(window) {
            return riff
        }
        if let isoBaseMedia = isoBaseMediaSignature(window) {
            return isoBaseMedia
        }
        if window.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            // EBML. Both Matroska and WebM live here; only the WebM identifier is
            // system-declared, and both are audiovisual either way.
            return SniffedContentType(
                identifier: "org.webmproject.webm",
                tabulatedFamily: .audiovisual
            )
        }
        if ascii(window, at: 0, count: 3) == "ID3" || isMPEGAudioFrameSync(window) {
            return SniffedContentType(identifier: "public.mp3", tabulatedFamily: .audio)
        }
        if ascii(window, at: 0, count: 4) == "OggS" {
            return SniffedContentType(identifier: "org.xiph.ogg", tabulatedFamily: .audio)
        }
        if ascii(window, at: 0, count: 4) == "fLaC" {
            return SniffedContentType(identifier: "org.xiph.flac", tabulatedFamily: .audio)
        }
        if ascii(window, at: 0, count: 4) == "FORM",
           ascii(window, at: 8, count: 4).map({ $0 == "AIFF" || $0 == "AIFC" }) == true {
            return SniffedContentType(
                identifier: "public.aiff-audio",
                tabulatedFamily: .audio
            )
        }
        if window.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            // Advanced Systems Format: the WMV and WMA container.
            return SniffedContentType(
                identifier: "com.microsoft.advanced-systems-format",
                tabulatedFamily: .audiovisual
            )
        }
        if window.starts(with: [0x00, 0x00, 0x01, 0xBA]) || window.starts(with: [0x00, 0x00, 0x01, 0xB3]) {
            return SniffedContentType(identifier: "public.mpeg", tabulatedFamily: .audiovisual)
        }
        if window.starts(with: [0x46, 0x4C, 0x56, 0x01]) {
            return SniffedContentType(
                identifier: "com.adobe.flash.video",
                tabulatedFamily: .audiovisual
            )
        }
        return nil
    }

    // MARK: - Container families that need a second field

    /// A RIFF container, distinguished by its four-character form type.
    private static func riffSignature(_ window: [UInt8]) -> SniffedContentType? {
        guard ascii(window, at: 0, count: 4) == "RIFF" else { return nil }
        switch ascii(window, at: 8, count: 4) {
        case "WEBP":
            return SniffedContentType(
                identifier: "org.webmproject.webp",
                tabulatedFamily: .stillImage
            )
        case "WAVE":
            return SniffedContentType(
                identifier: "com.microsoft.waveform-audio",
                tabulatedFamily: .audio
            )
        case "AVI ":
            return SniffedContentType(identifier: "public.avi", tabulatedFamily: .audiovisual)
        default:
            // An unknown RIFF form type. Leaving it unresolved lets Image I/O decide,
            // and a container Image I/O cannot read is malformed rather than assigned
            // to a family this table cannot establish.
            return nil
        }
    }

    /// An ISO base media container, distinguished by its `ftyp` brand.
    ///
    /// HEIC, HEIF, AVIF, MP4, QuickTime, 3GPP, and M4A share one box structure, so
    /// the brand is the only content-based way to tell a still image from a movie.
    /// An unrecognized brand resolves to audiovisual, which is the family the box
    /// structure was defined for; Image I/O still overrides that when it can
    /// actually read an image, so a brand this table does not list cannot make a
    /// readable still image unanalyzable.
    private static func isoBaseMediaSignature(_ window: [UInt8]) -> SniffedContentType? {
        guard ascii(window, at: 4, count: 4) == "ftyp", let brand = ascii(window, at: 8, count: 4) else {
            return nil
        }
        switch brand {
        case "heic", "heix", "heim", "heis":
            return SniffedContentType(identifier: "public.heic", tabulatedFamily: .stillImage)
        case "hevc", "hevx", "hevm", "hevs", "msf1":
            // HEIC image sequences. Readable by Image I/O, which reports more than
            // one frame, so they classify as multi-frame media.
            return SniffedContentType(identifier: "public.heics", tabulatedFamily: .stillImage)
        case "mif1", "mif2", "miaf":
            return SniffedContentType(identifier: "public.heif", tabulatedFamily: .stillImage)
        case "avif", "avis", "avio":
            return SniffedContentType(identifier: "public.avif", tabulatedFamily: .stillImage)
        case "M4A ", "M4B ", "M4P ":
            return SniffedContentType(
                identifier: "public.mpeg-4-audio",
                tabulatedFamily: .audio
            )
        case "qt  ":
            return SniffedContentType(
                identifier: "com.apple.quicktime-movie",
                tabulatedFamily: .audiovisual
            )
        default:
            let identifier: String
            if brand.hasPrefix("3g2") {
                identifier = "public.3gpp2"
            } else if brand.hasPrefix("3gp") {
                identifier = "public.3gpp"
            } else if brand.hasPrefix("M4V") {
                identifier = "com.apple.m4v-video"
            } else {
                identifier = "public.mpeg-4"
            }
            return SniffedContentType(identifier: identifier, tabulatedFamily: .audiovisual)
        }
    }

    /// Whether the window opens with an MPEG audio frame sync word.
    ///
    /// Eleven set bits followed by a defined version and layer. The version and
    /// layer fields are checked because eleven set bits alone appear in plenty of
    /// binary data, and a false audio classification would reject a supported image.
    private static func isMPEGAudioFrameSync(_ window: [UInt8]) -> Bool {
        guard window.count >= 2, window[0] == 0xFF, window[1] & 0xE0 == 0xE0 else { return false }
        let version = (window[1] & 0x18) >> 3
        let layer = (window[1] & 0x06) >> 1
        return version != 0b01 && layer != 0b00
    }

    // MARK: - Byte helpers

    /// The four-character-code style ASCII string at `offset`, or `nil` when the
    /// window is too short or the bytes are not printable ASCII.
    private static func ascii(_ window: [UInt8], at offset: Int, count: Int) -> String? {
        guard offset >= 0, count > 0, window.count >= offset + count else { return nil }
        var text = ""
        text.reserveCapacity(count)
        for byte in window[offset..<(offset + count)] {
            guard byte >= 0x20, byte < 0x7F else { return nil }
            text.append(Character(UnicodeScalar(byte)))
        }
        return text
    }
}
