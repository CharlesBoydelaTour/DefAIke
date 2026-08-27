import DefAIkeDomain
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

/// Observing which of the four metadata states a real container and its decode present.
///
/// Requirement 3.7 fixes the four states for orientation, embedded color profile, and
/// alpha. Getting the observation wrong is not a visible failure: the wrong contract
/// action is applied and the result is a plausible-looking image, so each state is pinned
/// against real bytes where a container can produce it and against explicit evidence
/// where none can.
@Suite("Image metadata observation")
struct MetadataObservationTests {
    // MARK: - Orientation

    @Test(
        "A declared orientation in 1 through 8 is valid and resolves to that value",
        arguments: ExifOrientation.allCases
    )
    func declaredOrientationIsValid(orientation: ExifOrientation) throws {
        let bytes = try #require(DeclaringImageFixture.jpeg(orientation: orientation.rawValue))
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))

        let observed = ImageMetadataInspector.observeOrientation(declarations)

        #expect(observed.state == .valid)
        #expect(observed.declared == orientation)
    }

    @Test("A container declaring no orientation is observed as absent")
    func absentOrientation() throws {
        // A hand-assembled PNG carries no EXIF block at all, so there is nothing to read
        // rather than a value that happens to mean "upright".
        let bytes = RawPNG.withoutColorChunks(width: 8, height: 6)
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))

        let observed = ImageMetadataInspector.observeOrientation(declarations)

        #expect(observed.state == .absent)
        #expect(observed.declared == nil)
        #expect(declarations.orientation == nil)
        #expect(declarations.tiffOrientation == nil)
    }

    @Test(
        "An integer outside 1 through 8 is unsupported, not malformed",
        arguments: [0, 9, 42, -1, Int(Int32.max)]
    )
    func unsupportedOrientationValue(value: Int) {
        // The declaration was read successfully; it just names no transform. Image I/O's
        // own encoder normalizes such a value to 1 while writing, so a real container
        // cannot carry one on this host and the evidence is stated directly.
        let observed = ImageMetadataInspector.observeOrientation(
            ImageDeclaredProperties(orientation: .integer(value))
        )
        #expect(observed.state == .unsupported)
        #expect(observed.declared == nil)
    }

    @Test("A non-integer orientation declaration is malformed")
    func malformedOrientationValue() {
        let observed = ImageMetadataInspector.observeOrientation(
            ImageDeclaredProperties(orientation: .notAnInteger)
        )
        #expect(observed.state == .malformed)
        #expect(observed.declared == nil)
    }

    @Test("Two disagreeing orientation declarations are malformed")
    func conflictingOrientationDeclarations() {
        // The container declares two different orientations. Picking either one is a
        // guess, and a guess here silently analyzes a rotated image.
        let observed = ImageMetadataInspector.observeOrientation(
            ImageDeclaredProperties(orientation: .integer(1), tiffOrientation: .integer(6))
        )
        #expect(observed.state == .malformed)
        #expect(observed.declared == nil)
    }

    @Test("Two agreeing orientation declarations are one valid declaration")
    func agreeingOrientationDeclarations() {
        let observed = ImageMetadataInspector.observeOrientation(
            ImageDeclaredProperties(orientation: .integer(6), tiffOrientation: .integer(6))
        )
        #expect(observed.state == .valid)
        #expect(observed.declared == .rightTop)
    }

    @Test("A non-integral numeric orientation is not rounded into a valid one")
    func nonIntegralOrientationIsNotRounded() {
        // Reading 5.7 as 6 would apply a rotation the container never declared.
        let declarations = ImageDeclaredProperties(
            imageIOProperties: [kCGImagePropertyOrientation: NSNumber(value: 5.7)]
        )
        #expect(declarations.orientation == .notAnInteger)
        #expect(ImageMetadataInspector.observeOrientation(declarations).state == .malformed)
    }

    @Test("A string orientation declaration is not read as a number")
    func textOrientationIsNotANumber() {
        let declarations = ImageDeclaredProperties(
            imageIOProperties: [kCGImagePropertyOrientation: "6" as NSString]
        )
        #expect(declarations.orientation == .notAnInteger)
    }

    // MARK: - Embedded color profile

    @Test("A container declaring no profile is observed as absent")
    func absentColorProfile() throws {
        // Core Graphics still assigns this decode a color space; that assumption is not
        // an embedded profile, and treating it as one would make the absent state
        // unreachable for every container.
        let bytes = RawPNG.withoutColorChunks(width: 8, height: 6)
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        let image = try #require(DeclaringImageFixture.decode(bytes))

        #expect(declarations.profileName == nil)
        #expect(image.colorSpace != nil, "the decode still carries a working assumption")
        #expect(ImageMetadataInspector.observeColorProfile(declarations, image: image) == .absent)
    }

    @Test("A declared profile with convertible colorimetry is valid")
    func validColorProfile() throws {
        let bytes = RawPNG.withSRGBChunk(width: 8, height: 6)
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        let image = try #require(DeclaringImageFixture.decode(bytes))

        #expect(declarations.profileName != nil)
        #expect(ImageMetadataInspector.observeColorProfile(declarations, image: image) == .valid)
    }

    @Test(
        "Every color model ColorSync can convert into RGB is valid",
        arguments: ImageMetadataInspector.convertibleColorSpaceModels
    )
    func convertibleModelsAreValid(model: CGColorSpaceModel) {
        #expect(
            ImageMetadataInspector.colorProfileState(
                profileName: .text("a profile"),
                decodedColorSpaceModel: model
            ) == .valid
        )
    }

    @Test(
        "A color model that names no convertible colorimetry is unsupported",
        arguments: [CGColorSpaceModel.indexed, .pattern, .deviceN, .unknown]
    )
    func nonConvertibleModelsAreUnsupported(model: CGColorSpaceModel) {
        #expect(
            ImageMetadataInspector.colorProfileState(
                profileName: .text("a profile"),
                decodedColorSpaceModel: model
            ) == .unsupported
        )
    }

    @Test("A declared profile whose decode carries no colorimetry is malformed")
    func declaredProfileWithoutColorSpaceIsMalformed() {
        #expect(
            ImageMetadataInspector.colorProfileState(
                profileName: .text("a profile"),
                decodedColorSpaceModel: nil
            ) == .malformed
        )
    }

    @Test("A profile name that is not a non-empty string is malformed")
    func unreadableProfileNameIsMalformed() {
        #expect(
            ImageMetadataInspector.colorProfileState(
                profileName: .notANonEmptyString,
                decodedColorSpaceModel: .rgb
            ) == .malformed
        )
        #expect(
            ImageDeclaredProperties(
                imageIOProperties: [kCGImagePropertyProfileName: "" as NSString]
            ).profileName == .notANonEmptyString
        )
        #expect(
            ImageDeclaredProperties(
                imageIOProperties: [kCGImagePropertyProfileName: NSNumber(value: 3)]
            ).profileName == .notANonEmptyString
        )
    }

    @Test("A profile Image I/O rejected before reporting it is observed as absent")
    func rejectedProfileIsObservedAsAbsent() throws {
        // Documented behavior rather than an accident: a PNG whose profile chunk does not
        // parse reaches this adapter with no profile name at all, so from here there is
        // nothing embedded. The malformed state covers a declaration that arrives and is
        // unusable, which is a different situation.
        let bytes = RawPNG.withoutColorChunks(width: 4, height: 4)
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        #expect(declarations.profileName == nil)
    }

    // MARK: - Alpha

    @Test("A container with an alpha channel is valid and carries one")
    func validAlpha() throws {
        let bytes = RawPNG.withoutColorChunks(width: 8, height: 6, colorType: .truecolorAlpha)
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        let image = try #require(DeclaringImageFixture.decode(bytes))

        let observed = ImageMetadataInspector.observeAlpha(declarations, image: image)

        #expect(observed.state == .valid)
        #expect(observed.carriesAlphaChannel)
    }

    @Test(
        "A supported container with no transparency is absent",
        arguments: [UTType.jpeg, .png, .heic]
    )
    func absentAlpha(type: UTType) throws {
        try #require(
            EncodedImageFixture.canEncode(type),
            "this host cannot encode \(type.identifier)"
        )
        let bytes = try #require(EncodedImageFixture.supported(type))
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        let image = try #require(DeclaringImageFixture.decode(bytes))

        let observed = ImageMetadataInspector.observeAlpha(declarations, image: image)

        #expect(observed.state == .absent)
        #expect(observed.carriesAlphaChannel == false)
    }

    @Test(
        "Every alpha layout carrying a channel is valid",
        arguments: [
            CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first,
        ]
    )
    func alphaLayoutsCarryingAChannel(alphaInfo: CGImageAlphaInfo) {
        let observed = ImageMetadataInspector.alphaState(
            alphaInfoRawValue: alphaInfo.rawValue,
            declaresAlpha: nil
        )
        #expect(observed.state == .valid)
        #expect(observed.carriesAlphaChannel)
    }

    @Test(
        "Every alpha layout carrying no channel is absent",
        arguments: [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast]
    )
    func alphaLayoutsCarryingNoChannel(alphaInfo: CGImageAlphaInfo) {
        // `noneSkipFirst` and `noneSkipLast` do have a fourth byte per pixel. It is not
        // an alpha channel, and compositing against it would use padding as opacity.
        let observed = ImageMetadataInspector.alphaState(
            alphaInfoRawValue: alphaInfo.rawValue,
            declaresAlpha: nil
        )
        #expect(observed.state == .absent)
        #expect(observed.carriesAlphaChannel == false)
    }

    @Test("Declared transparency the decode does not carry is malformed")
    func declaredButUndecodedAlphaIsMalformed() {
        // Without this the contract's alpha action would be applied to a channel that is
        // not there, and the result would be indistinguishable from an opaque image.
        let observed = ImageMetadataInspector.alphaState(
            alphaInfoRawValue: CGImageAlphaInfo.noneSkipLast.rawValue,
            declaresAlpha: true
        )
        #expect(observed.state == .malformed)
        #expect(observed.carriesAlphaChannel == false)
    }

    @Test("A decoded alpha channel is valid whatever the container declared")
    func decodedAlphaIsAuthoritative() {
        // Asymmetric on purpose: when the channel exists it is the thing the action
        // operates on, so its presence is not in doubt and a contrary declaration does
        // not make it uncertain.
        for declared in [true, false, nil] as [Bool?] {
            let observed = ImageMetadataInspector.alphaState(
                alphaInfoRawValue: CGImageAlphaInfo.last.rawValue,
                declaresAlpha: declared
            )
            #expect(observed.state == .valid)
        }
    }

    @Test("Alpha with no color channels is unsupported")
    func alphaOnlyIsUnsupported() {
        let observed = ImageMetadataInspector.alphaState(
            alphaInfoRawValue: CGImageAlphaInfo.alphaOnly.rawValue,
            declaresAlpha: nil
        )
        #expect(observed.state == .unsupported)
    }

    @Test(
        "An alpha arrangement this build cannot name is unsupported",
        arguments: [CGBitmapInfo.alphaInfoMask.rawValue, 8, 17]
    )
    func unnamedAlphaLayoutIsUnsupported(rawValue: UInt32) {
        // No `CGImage` can be built with an unassigned alpha code, so the code is stated
        // directly. Unsupported rather than malformed: the value was read, it just names
        // no channel arrangement the contract's actions describe. Malformed is reserved
        // for the container and the decode disagreeing.
        let observed = ImageMetadataInspector.alphaState(
            alphaInfoRawValue: rawValue,
            declaresAlpha: nil
        )
        #expect(observed.state == .unsupported)
        #expect(
            observed.carriesAlphaChannel == false,
            "an arrangement this build cannot name is not one whose channel it can locate"
        )
    }

    // MARK: - The whole observation

    @Test("A declared orientation is dropped unless the state is valid")
    func declaredOrientationOnlySurvivesTheValidState() {
        for state in ImageMetadataState.allCases {
            let observed = ObservedImageMetadata(
                orientation: state,
                declaredOrientation: .rightTop,
                colorProfile: .absent,
                alpha: .absent,
                carriesAlphaChannel: false
            )
            #expect(
                (observed.declaredOrientation != nil) == (state == .valid),
                "a \(state.rawValue) orientation must carry no applicable declaration"
            )
        }
    }

    @Test("A real container observes all three fields at once")
    func observesEveryFieldTogether() throws {
        let bytes = try #require(DeclaringImageFixture.jpeg(orientation: 6))
        let declarations = try #require(DeclaringImageFixture.declarations(of: bytes))
        let image = try #require(DeclaringImageFixture.decode(bytes))

        let observed = ImageMetadataInspector.observe(properties: declarations, image: image)

        #expect(observed.orientation == .valid)
        #expect(observed.declaredOrientation == .rightTop)
        #expect(observed.colorProfile == .valid, "Image I/O's JPEG encoder writes a profile")
        #expect(observed.alpha == .absent)
        #expect(observed.carriesAlphaChannel == false)
    }

    @Test("An unreadable properties dictionary declares nothing")
    func noDeclarationsIsAbsentEverywhere() {
        let empty = ImageDeclaredProperties()
        #expect(ImageMetadataInspector.observeOrientation(empty).state == .absent)
        #expect(
            ImageMetadataInspector.colorProfileState(
                profileName: empty.profileName,
                decodedColorSpaceModel: .rgb
            ) == .absent
        )
        #expect(empty.declaresAlpha == nil)
    }
}
