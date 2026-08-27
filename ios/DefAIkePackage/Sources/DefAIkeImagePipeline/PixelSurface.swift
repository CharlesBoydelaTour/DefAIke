import Accelerate
import DefAIkeDomain
import Foundation

// The pixel memory the transform works in.
//
// Two things make this a type rather than a bare `vImage_Buffer`:
//
//   * Lifetime. `vImage_Buffer` is a plain struct holding a raw pointer; both
//     `vImageBuffer_Init` and `vImageBuffer_InitWithCGImage` allocate memory the caller
//     must `free`. A transform with several intermediate buffers and an early return on
//     every framework failure — which is what "no implicit fallback" produces — is
//     exactly the shape that leaks. Tying the allocation to a class means the release
//     happens on every path, including the throwing ones, without a `defer` per buffer.
//
//   * Row stride. vImage pads rows for alignment, so a buffer it allocated is generally
//     *not* `width * channelCount` bytes per row. The contract's model input is a
//     tightly packed buffer (``PreparedPixelData`` in the Core ML adapter states the
//     same invariant), so somewhere the padding has to be removed. Keeping `rowBytes`
//     an explicit property of every surface, and offering a tightly packed allocation,
//     makes that a stated property of each buffer instead of an assumption.
//
// Not `Sendable`, and deliberately: a surface is raw mutable memory and stays inside the
// single preprocessing call that created it. What leaves the adapter is a token
// (``ModelInputToken``), never the memory.

/// One interleaved 8-bit-per-channel image buffer this module owns.
final class PixelSurface {
    /// Pixel width. Always positive.
    let width: Int

    /// Pixel height. Always positive.
    let height: Int

    /// Interleaved channels per pixel. Three for RGB, four for RGBA.
    let channelCount: Int

    /// Bytes between the start of one row and the start of the next.
    ///
    /// At least `width * channelCount`, and exactly that for a tightly packed surface.
    let rowBytes: Int

    /// The allocation. Non-optional, so there is no "surface with no memory" state and no
    /// reader that has to decide what to do about one.
    private let storage: UnsafeMutableRawPointer

    private init(
        width: Int,
        height: Int,
        channelCount: Int,
        rowBytes: Int,
        storage: UnsafeMutableRawPointer
    ) {
        self.width = width
        self.height = height
        self.channelCount = channelCount
        self.rowBytes = rowBytes
        self.storage = storage
    }

    deinit {
        free(storage)
    }

    /// Whether rows are packed with no padding.
    var isTightlyPacked: Bool { rowBytes == width * channelCount }

    /// The buffer descriptor vImage operates on.
    ///
    /// Rebuilt on each access rather than stored, so no caller can hold a descriptor
    /// whose pointer outlived the surface that owns it.
    var buffer: vImage_Buffer {
        vImage_Buffer(
            data: storage,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
    }

    /// The dimensions this surface covers.
    ///
    /// Non-optional because a surface cannot be created with a non-positive edge.
    var dimensions: PixelDimensions {
        // Safe: both edges were proved positive at allocation.
        PixelDimensions(width: width, height: height)!
    }

    /// Bytes this surface occupies, including any row padding.
    var allocatedByteCount: UInt64 { UInt64(rowBytes) * UInt64(height) }

    // MARK: - Allocation

    /// Allocates a tightly packed surface, or throws.
    ///
    /// "Tightly packed" is checked by construction rather than hoped for: `rowBytes` is
    /// set to `width * channelCount` and vImage is given that stride, so no alignment
    /// padding can appear in a buffer whose contents are about to be read as a
    /// contiguous byte sequence.
    static func tightlyPacked(
        width: Int,
        height: Int,
        channelCount: Int
    ) throws(PreprocessingFailure) -> PixelSurface {
        let failure = PreprocessingFailure.bufferUnavailable(
            width: width,
            height: height,
            channelCount: channelCount
        )
        guard width > 0, height > 0, channelCount > 0 else { throw failure }
        guard let byteCount = totalByteCount(
            width: width,
            height: height,
            channelCount: channelCount
        ) else {
            // A size that does not fit in `Int` cannot be allocated and cannot be
            // bounded by any budget. Not an allocation to attempt.
            throw failure
        }
        guard let storage = malloc(byteCount) else { throw failure }
        return PixelSurface(
            width: width,
            height: height,
            channelCount: channelCount,
            rowBytes: width * channelCount,
            storage: storage
        )
    }

    /// Takes ownership of a buffer vImage allocated.
    ///
    /// The buffer's memory becomes this surface's to free. On refusal the memory is
    /// released here, because the caller has already handed it over and would otherwise
    /// have to unwind an allocation it no longer describes.
    static func adopting(
        _ buffer: vImage_Buffer,
        channelCount: Int
    ) throws(PreprocessingFailure) -> PixelSurface {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        guard let storage = buffer.data,
              width > 0,
              height > 0,
              channelCount > 0,
              buffer.rowBytes >= width * channelCount
        else {
            free(buffer.data)
            throw .bufferUnavailable(width: width, height: height, channelCount: channelCount)
        }
        return PixelSurface(
            width: width,
            height: height,
            channelCount: channelCount,
            rowBytes: buffer.rowBytes,
            storage: storage
        )
    }

    /// Total bytes for a tightly packed surface, or `nil` when the product is not
    /// representable as an `Int`.
    static func totalByteCount(width: Int, height: Int, channelCount: Int) -> Int? {
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: channelCount)
        guard !rowOverflow else { return nil }
        let (total, totalOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !totalOverflow, total > 0 else { return nil }
        return total
    }

    /// An upper bound on the bytes vImage may allocate for these dimensions.
    ///
    /// vImage pads each row for alignment, so the true cost is at least
    /// `width * channelCount * height` and at most that plus one alignment quantum per
    /// row. The estimate rounds every row up, because it is compared against a hard
    /// budget limit before the allocation happens and an under-estimate would let the
    /// allocation through and detect the breach only after the memory was taken
    /// (Requirement 3.4's ordering).
    ///
    /// `nil` means the cost is not representable, which is not "small enough": the
    /// caller reports it as a fail-closed resource breach.
    static func estimatedAllocationByteCount(
        width: Int,
        height: Int,
        channelCount: Int,
        rowAlignment: Int = vImageRowAlignmentQuantum
    ) -> UInt64? {
        guard width > 0, height > 0, channelCount > 0, rowAlignment > 0 else { return nil }
        let (rowBytes, rowOverflow) = UInt64(width).multipliedReportingOverflow(
            by: UInt64(channelCount)
        )
        guard !rowOverflow else { return nil }
        let (padded, padOverflow) = rowBytes.addingReportingOverflow(UInt64(rowAlignment - 1))
        guard !padOverflow else { return nil }
        let alignedRowBytes = padded - padded % UInt64(rowAlignment)
        let (total, totalOverflow) = alignedRowBytes.multipliedReportingOverflow(
            by: UInt64(height)
        )
        guard !totalOverflow else { return nil }
        return total
    }

    /// Row alignment vImage is documented to use when it allocates.
    ///
    /// A structural property of the framework's allocator, not an approved resource
    /// value: it only makes the allocation estimate an over-estimate rather than an
    /// under-estimate.
    static let vImageRowAlignmentQuantum = 64

    // MARK: - Reading

    /// The surface's contents as a tightly packed row-major byte sequence.
    ///
    /// Row padding is dropped, so the result is exactly `width * height * channelCount`
    /// bytes regardless of how the surface was allocated. Copying is the point: this is
    /// how pixel bytes leave the raw allocation, and the alternative is exposing the
    /// pointer.
    func copyPackedBytes() -> [UInt8] {
        let packedRowBytes = width * channelCount
        var bytes = [UInt8](repeating: 0, count: packedRowBytes * height)
        let base = storage.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeMutableBufferPointer { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                (target + row * packedRowBytes).update(
                    from: base + row * rowBytes,
                    count: packedRowBytes
                )
            }
        }
        return bytes
    }
}
