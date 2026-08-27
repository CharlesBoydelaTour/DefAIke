import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeSharedTransfer

/// Known-answer and partition tests for the streaming hasher.
///
/// The digest is the whole basis for "byte-for-byte identical" across a process boundary
/// (Requirements 2.9 through 2.13 and 2.19), so it is checked against published SHA-256
/// vectors rather than against itself, and against arbitrary chunk partitions rather than
/// against one convenient buffer size.
@Suite("Streaming SHA-256")
struct StreamingSHA256Tests {

    @Test("The empty stream digests to the published SHA-256 value")
    func emptyStream() {
        let hasher = StreamingSHA256()
        #expect(hasher.byteCount == 0)
        #expect(
            hasher.digest().hexadecimalString
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("A known input digests to the published SHA-256 value")
    func knownAnswer() {
        var hasher = StreamingSHA256()
        hasher.update(Array("abc".utf8))
        #expect(hasher.byteCount == 3)
        #expect(
            hasher.digest().hexadecimalString
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("A one-shot digest matches the incremental digest of the same bytes")
    func oneShotMatchesIncremental() {
        let bytes = Sample.bytes(count: 5_000)
        var hasher = StreamingSHA256()
        hasher.update(bytes)
        #expect(hasher.digest() == StreamingSHA256.digest(of: Data(bytes)))
    }

    @Test(
        "Every chunk partition of the same bytes yields the same digest and count",
        arguments: [1, 2, 3, 7, 64, 511, 512, 4_096, 10_000]
    )
    func partitionInvariance(chunkSize: Int) {
        let bytes = Sample.bytes(count: 3_333)
        let expected = StreamingSHA256.digest(of: Data(bytes))

        var hasher = StreamingSHA256()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            hasher.update(Array(bytes[offset..<end]))
            offset = end
        }

        #expect(hasher.digest() == expected)
        #expect(hasher.byteCount == UInt64(bytes.count))
    }

    @Test("Empty chunks change neither the digest nor the count")
    func emptyChunksAreInert() {
        let bytes = Sample.bytes(count: 100)
        var hasher = StreamingSHA256()
        hasher.update([UInt8]())
        hasher.update(bytes)
        hasher.update(Data())
        #expect(hasher.byteCount == 100)
        #expect(hasher.digest() == StreamingSHA256.digest(of: Data(bytes)))
    }

    @Test("Taking a digest does not end the stream")
    func digestIsNonConsuming() {
        let first = Sample.bytes(count: 40)
        let second = Sample.bytes(count: 40, seed: 200)

        var hasher = StreamingSHA256()
        hasher.update(first)
        let interim = hasher.digest()
        hasher.update(second)

        #expect(interim == StreamingSHA256.digest(of: Data(first)))
        #expect(hasher.digest() == StreamingSHA256.digest(of: Data(first + second)))
        #expect(hasher.byteCount == 80)
    }

    @Test("One flipped byte changes the digest")
    func mutationChangesDigest() {
        var bytes = Sample.bytes(count: 512)
        let original = StreamingSHA256.digest(of: Data(bytes))
        bytes[256] ^= 0x01
        #expect(StreamingSHA256.digest(of: Data(bytes)) != original)
    }
}
