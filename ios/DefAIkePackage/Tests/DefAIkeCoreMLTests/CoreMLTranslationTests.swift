import DefAIkeDomain
import CoreML
import CoreVideo
import Testing

@testable import DefAIkeCoreML

// The framework-facing translations, exercised with real Core ML and Core Video values
// but no compiled model.
//
// **These are host development checks.** They prove that a feature value is projected
// into the right case and that a prepared buffer lands in the right bytes. They prove
// nothing about the released model: reading a real generated description, running a real
// prediction, and comparing against parity fixtures need a real `.mlmodelc` and belong
// to task 6.11, and latency, memory, energy, thermals, and Apple Neural Engine placement
// are physical-device measurements that no test in this package can establish.

@Suite("Core ML value translation")
struct CoreMLFeatureProjectionTests {
    @Test("A double feature is one scalar")
    func projectsDouble() {
        #expect(
            CoreMLModelRuntime.project(MLFeatureValue(double: -2.5)) == .scalar(-2.5)
        )
    }

    @Test("An integer feature is one scalar")
    func projectsInt64() {
        #expect(CoreMLModelRuntime.project(MLFeatureValue(int64: 3)) == .scalar(3))
    }

    @Test("A nonfinite double reaches the output check rather than being rejected here")
    func projectsNonFinite() {
        // One place decides `invalid-output-error`, and it is not this projection.
        guard case .scalar(let value) = CoreMLModelRuntime.project(
            MLFeatureValue(double: .nan)
        ) else {
            Issue.record("a NaN double must still project as a scalar")
            return
        }
        #expect(value.isNaN)
    }

    @Test("A one-element multiarray is one scalar", arguments: [[1], [1, 1], [1, 1, 1]])
    func projectsSingleElementMultiArray(shape: [Int]) throws {
        let array = try MLMultiArray(
            shape: shape.map { NSNumber(value: $0) },
            dataType: .float32
        )
        array[0] = NSNumber(value: 0.75)

        #expect(
            CoreMLModelRuntime.project(MLFeatureValue(multiArray: array)) == .scalar(0.75)
        )
    }

    @Test("A multiarray holding anything other than one element is nonscalar")
    func projectsMultiElementMultiArray() throws {
        let array = try MLMultiArray(shape: [3], dataType: .float32)

        #expect(
            CoreMLModelRuntime.project(MLFeatureValue(multiArray: array))
                == .nonScalar(elementCount: 3)
        )
    }

    @Test("A value that is not a number is nonnumeric")
    func projectsNonNumeric() throws {
        #expect(CoreMLModelRuntime.project(MLFeatureValue(string: "fake")) == .nonNumeric)

        let pixels = PixelFixture.bound(edge: 2)
        let buffer = try #require(
            CoreMLModelRuntime.pixelBuffer(from: pixels, format: .bgra8)
        )
        #expect(CoreMLModelRuntime.project(MLFeatureValue(pixelBuffer: buffer)) == .nonNumeric)
    }

    @Test("Element types this build does not name fail closed as other")
    func projectsElementTypes() {
        #expect(CoreMLModelRuntime.element(.float16) == .float16)
        #expect(CoreMLModelRuntime.element(.float32) == .float32)
        #expect(CoreMLModelRuntime.element(.double) == .float64)
        #expect(CoreMLModelRuntime.element(.int32) == .int32)
        // `other` is refused by the schema check, so an element type added by a later
        // SDK cannot be accepted as a logit by accident.
        #expect(!RuntimeElementType.other.isFloatingPoint)
    }

    @Test("Pixel formats map to the three this build can write, or to other")
    func projectsPixelFormats() {
        #expect(CoreMLModelRuntime.pixelFormat(kCVPixelFormatType_32BGRA) == .bgra8)
        #expect(CoreMLModelRuntime.pixelFormat(kCVPixelFormatType_32ARGB) == .argb8)
        #expect(CoreMLModelRuntime.pixelFormat(kCVPixelFormatType_OneComponent8) == .grayscale8)
        #expect(CoreMLModelRuntime.pixelFormat(kCVPixelFormatType_420YpCbCr8Planar) == .other)
    }

    @Test("The image input is read from a schema that declares exactly one")
    func readsSingleImageInput() {
        let input = CoreMLModelRuntime.imageInput(in: SchemaFixture.matching())
        #expect(input?.name == "image")
        #expect(input?.width == CenterCropContract.requiredEdge)
        #expect(input?.height == CenterCropContract.requiredEdge)
        #expect(input?.pixelFormat == .bgra8)

        #expect(CoreMLModelRuntime.imageInput(in: SchemaFixture.withInputKind(.unsupported)) == nil)
        #expect(
            CoreMLModelRuntime.imageInput(
                in: RuntimeModelSchema(inputs: [], outputs: [])
            ) == nil
        )
    }
}

@Suite("Core ML input buffer construction")
struct CoreMLPixelBufferTests {
    /// Two pixels of known, distinguishable channel values.
    private static let redThenGreen: [UInt8] = [
        0xF0, 0x10, 0x20,
        0x11, 0xE0, 0x22,
        0x33, 0x44, 0xD0,
        0x01, 0x02, 0x03,
    ]

    private func pixels() -> PreparedPixelData {
        guard let pixels = PreparedPixelData(
            edge: 2,
            channelOrder: .rgb,
            bytes: Self.redThenGreen
        ) else {
            preconditionFailure("the fixture must satisfy the packing invariant")
        }
        return pixels
    }

    /// Reads the buffer back, honoring the row stride Core Video chose.
    private func bytes(of buffer: CVPixelBuffer) -> [[UInt8]] {
        #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let source = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        return (0..<CVPixelBufferGetHeight(buffer)).map { row in
            (0..<(width * 4)).map { source[row * stride + $0] }
        }
    }

    @Test("A BGRA buffer carries the RGB channels in blue, green, red order")
    func writesBGRA() throws {
        let buffer = try #require(
            CoreMLModelRuntime.pixelBuffer(from: pixels(), format: .bgra8)
        )

        #expect(CVPixelBufferGetWidth(buffer) == 2)
        #expect(CVPixelBufferGetHeight(buffer) == 2)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(bytes(of: buffer) == [
            // (R F0 G 10 B 20) becomes B G R A, and alpha is opaque because the bound
            // contract has already resolved alpha.
            [0x20, 0x10, 0xF0, 0xFF, 0x22, 0xE0, 0x11, 0xFF],
            [0xD0, 0x44, 0x33, 0xFF, 0x03, 0x02, 0x01, 0xFF],
        ])
    }

    @Test("An ARGB buffer carries the RGB channels in alpha, red, green, blue order")
    func writesARGB() throws {
        let buffer = try #require(
            CoreMLModelRuntime.pixelBuffer(from: pixels(), format: .argb8)
        )

        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32ARGB)
        #expect(bytes(of: buffer) == [
            [0xFF, 0xF0, 0x10, 0x20, 0xFF, 0x11, 0xE0, 0x22],
            [0xFF, 0x33, 0x44, 0xD0, 0xFF, 0x01, 0x02, 0x03],
        ])
    }

    @Test(
        "A format that is not one this build can write is refused rather than guessed",
        arguments: [RuntimeImagePixelFormat.grayscale8, .other]
    )
    func refusesUnwritableFormats(format: RuntimeImagePixelFormat) {
        #expect(CoreMLModelRuntime.pixelBuffer(from: pixels(), format: format) == nil)
    }

    @Test("The bound 384-pixel square is written in full")
    func writesBoundSquare() throws {
        let buffer = try #require(
            CoreMLModelRuntime.pixelBuffer(from: PixelFixture.bound(), format: .bgra8)
        )

        #expect(CVPixelBufferGetWidth(buffer) == CenterCropContract.requiredEdge)
        #expect(CVPixelBufferGetHeight(buffer) == CenterCropContract.requiredEdge)
        // Every written channel came from the source pattern, and no row was skipped:
        // a stride mistake would leave zeroed bytes at the end of the last row.
        let rows = bytes(of: buffer)
        #expect(rows.count == CenterCropContract.requiredEdge)
        #expect(rows.allSatisfy { row in
            row.enumerated().allSatisfy { index, value in
                index % 4 == 3 ? value == 0xFF : value == 0x7F
            }
        })
    }
}
