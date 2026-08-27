import DefAIkeDomain
import UniformTypeIdentifiers

// Deciding what the bytes actually are.
//
// Two authorities, in a fixed order of precedence:
//
//   1. Image I/O, for anything it can read. It is the decoder that will be asked to
//      produce pixels, so its view of the container type and image count is the one
//      that matters (design: "Image I/O reads the actual container type and image
//      count; an extension or UTI hint is not trusted").
//   2. The content signature table, for the families Image I/O does not read at all.
//      Without it a QuickTime movie and a buffer of random bytes are the same "no
//      source" answer, and Requirement 1.11 needs the movie recognized as media.
//
// Neither authority is a file name, a path extension, or the provider's declared type
// hint. None of those is consulted anywhere in this file.

/// Classifies retained encoded bytes into exactly one ``MediaClassification``.
public enum ContainerClassifier {
    /// The classification of `bytes` under the bound contract's supported set.
    ///
    /// `supportedContainers` comes from the Analysis Session's bound Preprocessing
    /// Contract rather than from a constant here, so the accepted set is a property of
    /// the signed artifact. The contract schema already fixes it to all four Version 1
    /// containers; reading it from the contract keeps that a single decision in one
    /// place instead of two that could drift.
    public static func classify(
        bytes: [UInt8],
        supportedContainers: Set<StaticContainer>
    ) -> MediaClassification {
        classify(
            bytes: bytes,
            source: EncodedImageSource(bytes: bytes),
            supportedContainers: supportedContainers
        )
    }

    /// The classification of `bytes`, reusing a reader the caller already opened.
    ///
    /// Opening a reader copies the encoded bytes into a Core Foundation buffer, and the
    /// validator needs the same reader afterwards for the declared properties and the
    /// decode. Passing it in keeps that to one copy, which matters because the memory it
    /// occupies counts against the same budget this classification precedes.
    ///
    /// `source` is `nil` when Image I/O could not open the bytes at all.
    static func classify(
        bytes: [UInt8],
        source: EncodedImageSource?,
        supportedContainers: Set<StaticContainer>
    ) -> MediaClassification {
        let signature = ContentSignature.sniff(bytes)

        guard let source else {
            return classifyWithoutImageIO(signature, supportedContainers: supportedContainers)
        }
        guard let contentType = source.contentType else {
            return classifyWithoutImageIO(signature, supportedContainers: supportedContainers)
        }

        // Image I/O opens a few containers that are not images. A PDF is the one that
        // matters: it reports a type and a page count, and treating a page count as a
        // frame count would call a one-page PDF an analyzable static image.
        if let family = SniffedContentFamily(declaring: contentType) {
            switch family {
            case .audio:
                return .audio
            case .audiovisual:
                return .video
            case .otherStaticContainer:
                return .unsupportedStatic
            case .stillImage:
                break
            }
        } else {
            return .unsupportedStatic
        }

        let frameCount = source.frameCount
        if frameCount > 1 {
            return .animatedOrMultiFrame
        }
        if frameCount < 1 {
            // A recognized image type holding no image: truncated before the first
            // frame exists. Malformed, not an unsupported format.
            return .malformed
        }
        guard let container = staticContainer(for: contentType) else {
            return .unsupportedStatic
        }
        guard supportedContainers.contains(container) else {
            return .unsupportedStatic
        }
        return .supportedStatic(container)
    }

    /// The classification when Image I/O produced no readable container.
    ///
    /// The signature family decides. A still-image signature that Image I/O cannot
    /// read splits on the bound contract: a supported container that will not open is
    /// malformed, while an unsupported one is reported as the unsupported format it
    /// is, because Requirement 1.13 is about the format rather than about whether this
    /// build happens to have a decoder for it.
    private static func classifyWithoutImageIO(
        _ signature: SniffedContentType?,
        supportedContainers: Set<StaticContainer>
    ) -> MediaClassification {
        guard let signature else { return .malformed }
        switch signature.family {
        case .audio:
            return .audio
        case .audiovisual:
            return .video
        case .otherStaticContainer:
            return .unsupportedStatic
        case .stillImage:
            guard let type = signature.type,
                  let container = staticContainer(for: type),
                  supportedContainers.contains(container)
            else {
                return .unsupportedStatic
            }
            return .malformed
        }
    }

    /// The Supported Static Image container a type names, or `nil`.
    ///
    /// Conformance rather than identifier equality, so a system subtype of a supported
    /// container still resolves. HEIC is tested before HEIF because neither of the two
    /// conforms to the other and the Evidence Report records which one was read.
    ///
    /// `public.heif-standard` is deliberately *not* one of the tests, even though it
    /// looks like the natural way to spell "the HEIF family". It is the declared
    /// parent of `public.avif` and `public.heics` as well as of HEIC and HEIF, so
    /// accepting it would silently widen the Version 1 supported set to AVIF, which
    /// Requirement 1.13 places outside it and which no calibration or parity evidence
    /// covers.
    static func staticContainer(for type: UTType) -> StaticContainer? {
        if type.conforms(to: .jpeg) {
            return .jpeg
        }
        if type.conforms(to: .png) {
            return .png
        }
        if type.conforms(to: .heic) {
            return .heic
        }
        if type.conforms(to: .heif) {
            return .heif
        }
        return nil
    }
}
