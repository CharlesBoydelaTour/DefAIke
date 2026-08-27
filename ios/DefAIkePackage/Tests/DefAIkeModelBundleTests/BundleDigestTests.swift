import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Stream hashing and the deterministic directory-tree digest.
///
/// A digest that is not mutation-sensitive would silently weaken every artifact check
/// built on it, so these tests are about sensitivity as much as about correctness: the
/// known-answer vectors prove the hash is SHA-256, and the tree cases prove that adding,
/// removing, renaming, or moving anything inside a tree changes its digest.
@Suite("Bundle digests")
struct BundleDigestTests {
    // MARK: Stream hashing

    @Test("Stream hashing matches the published SHA-256 vectors")
    func knownAnswerVectors() {
        let vectors: [(message: String, digest: String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]
        for vector in vectors {
            let digest = StreamingSHA256.digest(of: Array(vector.message.utf8))
            #expect(digest.hexadecimalString == vector.digest)
        }
    }

    @Test("Chunk boundaries cannot change a digest")
    func chunkPartitionInvariance() {
        let message = Array("the quick brown fox jumps over the lazy dog".utf8)
        let whole = StreamingSHA256.digest(of: message)

        for stride in [1, 2, 3, 7, 16, message.count - 1, message.count, message.count + 5] {
            var hasher = StreamingSHA256()
            var offset = 0
            while offset < message.count {
                let end = min(offset + stride, message.count)
                hasher.update(message[offset..<end])
                offset = end
            }
            #expect(hasher.finalize() == whole, "stride \(stride) produced a different digest")
        }
    }

    // MARK: Tree digest

    private func member(_ path: String, _ text: String) -> BundleTreeDigest.Member {
        let bytes = Array(text.utf8)
        return .file(
            relativePath: path,
            byteCount: UInt64(bytes.count),
            digest: StreamingSHA256.digest(of: bytes)
        )
    }

    private var baseline: [BundleTreeDigest.Member] {
        [
            member("coremldata.bin", "core-ml-data"),
            .directory(relativePath: "weights"),
            member("weights/weight.bin", "weight-blob"),
        ]
    }

    private func digest(_ members: [BundleTreeDigest.Member]) -> DefAIkeDomain.SHA256Digest {
        BundleTreeDigest.digest(of: members, construction: .sortedKindTaggedRecords)
    }

    @Test("Enumeration order cannot change a tree digest")
    func orderIndependence() {
        let expected = digest(baseline)
        #expect(digest(baseline.reversed()) == expected)
        #expect(digest([baseline[1], baseline[2], baseline[0]]) == expected)
    }

    @Test("Adding, removing, renaming, or duplicating a member changes the digest")
    func structuralSensitivity() {
        let expected = digest(baseline)

        var added = baseline
        added.append(member("extra.bin", "extra"))
        #expect(digest(added) != expected)

        var removed = baseline
        removed.removeLast()
        #expect(digest(removed) != expected)

        var renamed = baseline
        renamed[0] = member("coremldata.dat", "core-ml-data")
        #expect(digest(renamed) != expected)

        var duplicated = baseline
        duplicated.append(baseline[0])
        #expect(digest(duplicated) != expected)
    }

    @Test("Adding an empty directory changes the digest")
    func emptyDirectorySensitivity() {
        var withEmptyDirectory = baseline
        withEmptyDirectory.append(.directory(relativePath: "analytics"))
        #expect(digest(withEmptyDirectory) != digest(baseline))
    }

    @Test("A file and a directory at the same path digest differently")
    func kindSensitivity() {
        let asDirectory: [BundleTreeDigest.Member] = [.directory(relativePath: "weights")]
        let asEmptyFile: [BundleTreeDigest.Member] = [
            .file(relativePath: "weights", byteCount: 0, digest: StreamingSHA256.digest(of: []))
        ]
        #expect(digest(asDirectory) != digest(asEmptyFile))
    }

    @Test("Changing one byte of one member changes the digest")
    func contentSensitivity() {
        var mutated = baseline
        mutated[2] = member("weights/weight.bin", "weight-blOb")
        #expect(digest(mutated) != digest(baseline))
    }

    @Test("Moving bytes between two members changes the digest")
    func lengthPrefixingPreventsRunTogether() {
        let split: [BundleTreeDigest.Member] = [
            member("a", "one"), member("b", "twothree"),
        ]
        let shifted: [BundleTreeDigest.Member] = [
            member("a", "onetwo"), member("b", "three"),
        ]
        #expect(digest(split) != digest(shifted))
    }

    @Test("Splitting a path across name and content changes the digest")
    func pathAndContentAreSeparated() {
        let left: [BundleTreeDigest.Member] = [member("ab", "cd")]
        let right: [BundleTreeDigest.Member] = [member("a", "bcd")]
        #expect(digest(left) != digest(right))
    }

    @Test("An empty tree still produces a digest, distinct from any populated tree")
    func emptyTreeIsTotal() {
        #expect(digest([]) != digest(baseline))
    }

    @Test("The same members digest identically across runs")
    func repeatability() {
        #expect(digest(baseline) == digest(baseline))
    }
}
