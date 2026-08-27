import Accelerate
import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeImagePipeline

/// The pixel memory the transform works in.
///
/// Two invariants carry real weight: a surface the transform hands on is tightly packed,
/// and a size that cannot be represented is refused rather than wrapped. Both exist
/// because getting them wrong produces plausible-looking pixels instead of a failure.
@Suite("Pixel surfaces")
struct PixelSurfaceTests {
    @Test("A tightly packed surface has no row padding")
    func tightlyPackedRows() throws {
        // 13 is deliberately awkward: 39 bytes a row is a stride vImage would pad.
        let surface = try PixelSurface.tightlyPacked(width: 13, height: 7, channelCount: 3)
        #expect(surface.rowBytes == 39)
        #expect(surface.isTightlyPacked)
        #expect(surface.allocatedByteCount == 273)
        #expect(surface.copyPackedBytes().count == 273)
        #expect(surface.dimensions == PixelDimensions(width: 13, height: 7))
    }

    @Test("A non-positive edge or channel count is not allocatable")
    func nonPositiveGeometryIsRefused() {
        for (width, height, channels) in [(0, 4, 3), (4, 0, 3), (4, 4, 0), (-1, 4, 3)] {
            #expect(throws: PreprocessingFailure.self) {
                try PixelSurface.tightlyPacked(
                    width: width,
                    height: height,
                    channelCount: channels
                )
            }
        }
    }

    @Test("A size that does not fit in an Int is refused, not wrapped")
    func unrepresentableSizeIsRefused() {
        #expect(PixelSurface.totalByteCount(width: 13, height: 7, channelCount: 3) == 273)
        #expect(PixelSurface.totalByteCount(width: Int.max, height: 2, channelCount: 3) == nil)
        #expect(
            PixelSurface.totalByteCount(width: 1 << 40, height: 1 << 30, channelCount: 4) == nil
        )
        #expect(throws: PreprocessingFailure.self) {
            try PixelSurface.tightlyPacked(width: Int.max, height: 2, channelCount: 4)
        }
    }

    @Test("The allocation estimate never under-counts what vImage will take")
    func estimateIsAnOverEstimate() throws {
        // Requirement 3.4's ordering depends on this: the breach has to be detectable
        // before the memory is taken, so the estimate must be at least the allocation.
        for (width, height, channels) in [(13, 7, 3), (8, 6, 4), (1, 1, 4), (447, 313, 4)] {
            let estimate = try #require(
                PixelSurface.estimatedAllocationByteCount(
                    width: width,
                    height: height,
                    channelCount: channels
                )
            )
            let tight = try #require(
                PixelSurface.totalByteCount(
                    width: width,
                    height: height,
                    channelCount: channels
                )
            )
            #expect(estimate >= UInt64(tight))

            var allocated = vImage_Buffer()
            let status = vImageBuffer_Init(
                &allocated,
                vImagePixelCount(height),
                vImagePixelCount(width),
                UInt32(channels * 8),
                vImage_Flags(kvImageNoFlags)
            )
            #expect(status == kvImageNoError)
            let surface = try PixelSurface.adopting(allocated, channelCount: channels)
            #expect(
                surface.allocatedByteCount <= estimate,
                """
                \(width)x\(height)x\(channels): vImage took \
                \(surface.allocatedByteCount) but the estimate was \(estimate)
                """
            )
        }
    }

    @Test("An unrepresentable estimate is nil rather than a wrapped number")
    func estimateOverflowIsNil() {
        #expect(
            PixelSurface.estimatedAllocationByteCount(
                width: 65_535,
                height: 65_535,
                channelCount: 4
            ) != nil,
            "a large but representable cost still has a number"
        )
        #expect(
            PixelSurface.estimatedAllocationByteCount(
                width: Int.max,
                height: Int.max,
                channelCount: 4
            ) == nil
        )
        #expect(
            PixelSurface.estimatedAllocationByteCount(
                width: 4,
                height: 4,
                channelCount: 4,
                rowAlignment: 0
            ) == nil
        )
    }

    @Test("Packed bytes drop the padding of an adopted buffer")
    func packedBytesDropPadding() throws {
        // A vImage-allocated buffer generally has a padded stride. Reading it as if it were
        // packed would shear the image by a few pixels a row, which survives resizing and
        // still looks like a photograph.
        var allocated = vImage_Buffer()
        let status = vImageBuffer_Init(&allocated, 4, 13, 24, vImage_Flags(kvImageNoFlags))
        try #require(status == kvImageNoError)
        let surface = try PixelSurface.adopting(allocated, channelCount: 3)
        try #require(surface.rowBytes > 39, "this test needs a padded stride to be meaningful")

        // Fill every byte, padding included, so a reader that kept the padding would see
        // the sentinel.
        let base = surface.buffer.data!.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(surface.rowBytes * surface.height) { base[index] = 0xEE }
        for row in 0..<surface.height {
            for column in 0..<(surface.width * 3) {
                base[row * surface.rowBytes + column] = UInt8((row * 41 + column) % 251)
            }
        }

        let packed = surface.copyPackedBytes()
        #expect(packed.count == 13 * 4 * 3)
        #expect(packed.contains(0xEE) == false, "padding must not appear in the packed bytes")
        for row in 0..<4 {
            for column in 0..<39 {
                #expect(packed[row * 39 + column] == UInt8((row * 41 + column) % 251))
            }
        }
    }

    @Test("A buffer whose stride cannot hold its rows is refused")
    func adoptingRejectsAnImpossibleStride() {
        // Deliberately inconsistent: 4 channels of 13 pixels cannot fit in 39 bytes. The
        // memory is released by the refusal rather than leaked.
        var allocated = vImage_Buffer()
        let status = vImageBuffer_Init(&allocated, 4, 13, 24, vImage_Flags(kvImageNoFlags))
        #expect(status == kvImageNoError)
        #expect(throws: PreprocessingFailure.self) {
            try PixelSurface.adopting(allocated, channelCount: 4)
        }
    }

    @Test("An empty buffer descriptor is refused")
    func adoptingRejectsAnEmptyDescriptor() {
        #expect(throws: PreprocessingFailure.self) {
            try PixelSurface.adopting(vImage_Buffer(), channelCount: 4)
        }
    }
}
