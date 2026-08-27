import DefAIkeDomain
import Testing

@testable import DefAIkeTestSupport

/// Verifies the test-only SHA-256 against published known-answer vectors.
///
/// Every byte-identity and handoff-mutation property depends on this digest actually
/// being SHA-256. If it were subtly wrong, a single flipped byte could pass an identity
/// check and those properties would silently stop testing anything. The vectors come from
/// the FIPS 180-4 examples and the standard empty-input value; they are not derived from
/// this implementation.
@Suite("Test SHA-256 correctness")
struct TestSHA256Tests {

    @Test("Digest of the empty message matches the published vector")
    func emptyMessage() {
        #expect(
            TestSHA256.digest(of: []).hexadecimalString
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("Digest of \"abc\" matches the published vector")
    func shortMessage() {
        #expect(
            TestSHA256.digest(ofUTF8: "abc").hexadecimalString
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("Digest of a 56-byte message crosses the padding boundary correctly")
    func paddingBoundaryMessage() {
        // 56 bytes is exactly the point where the length field no longer fits in the
        // final block, so this vector exercises the extra-block padding path.
        #expect(
            TestSHA256.digest(
                ofUTF8: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            ).hexadecimalString
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    @Test("Digest of a multi-block message matches the published vector")
    func multiBlockMessage() {
        #expect(
            TestSHA256.digest(ofUTF8: String(repeating: "a", count: 1_000_000))
                .hexadecimalString
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    @Test(
        "Any chunk partition of the same bytes produces the same digest",
        arguments: [1, 2, 3, 7, 31, 63, 64, 65, 127, 256]
    )
    func chunkPartitionInvariance(chunkSize: Int) {
        let message = PortValue.bytes(count: 500)
        var hasher = TestSHA256.Hasher()
        var offset = 0
        while offset < message.count {
            let end = min(offset + chunkSize, message.count)
            hasher.update(Array(message[offset..<end]))
            offset = end
        }
        #expect(hasher.finalize() == TestSHA256.digest(of: message))
    }

    @Test("A single flipped byte changes the digest")
    func mutationSensitivity() {
        var mutated = PortValue.bytes(count: 200)
        let original = TestSHA256.digest(of: mutated)
        mutated[137] = mutated[137] ^ 0x01
        #expect(TestSHA256.digest(of: mutated) != original)
    }

    @Test("Truncating the message changes the digest")
    func lengthSensitivity() {
        let message = PortValue.bytes(count: 200)
        #expect(TestSHA256.digest(of: message) != TestSHA256.digest(of: Array(message.dropLast())))
    }
}
