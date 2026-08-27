import DefAIkeDomain

/// SHA-256 for test doubles only.
///
/// The in-memory store has to produce digests that are *actually* mutation-sensitive.
/// A stand-in such as a length-and-XOR sum would let a single flipped byte pass a
/// byte-identity check, which would silently weaken exactly the properties that check
/// depends on: handoff byte preservation and fail-closed handoff mutation
/// (Properties 5 and 6).
///
/// This is not shipping code and is not a cryptographic claim. Shipping adapters use
/// the platform's CryptoKit implementation while streaming; this exists so a test never
/// needs CryptoKit, a file system, or a real provider to get a correct digest. It is
/// verified against the published SHA-256 known-answer vectors in
/// `TestDoubleTests/TestSHA256Tests`.
public enum TestSHA256 {
    /// Digest of a complete message.
    public static func digest(of message: [UInt8]) -> SHA256Digest {
        var hasher = Hasher()
        hasher.update(message)
        return hasher.finalize()
    }

    /// Digest of a UTF-8 string, for known-answer vectors and readable fixtures.
    public static func digest(ofUTF8 text: String) -> SHA256Digest {
        digest(of: Array(text.utf8))
    }

    /// Incremental SHA-256.
    ///
    /// Chunked so a double can hash the same way an adapter does: once, while the bytes
    /// stream past. Any partition of the same byte sequence produces the same digest,
    /// which is the invariant a chunk-partition property relies on.
    public struct Hasher {
        private var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        private var pending: [UInt8] = []
        private var messageByteCount: UInt64 = 0

        public init() {}

        /// Absorbs the next chunk.
        public mutating func update(_ chunk: [UInt8]) {
            messageByteCount &+= UInt64(chunk.count)
            pending.append(contentsOf: chunk)
            var consumed = 0
            while pending.count - consumed >= 64 {
                compress(Array(pending[consumed..<(consumed + 64)]))
                consumed += 64
            }
            if consumed > 0 {
                pending.removeFirst(consumed)
            }
        }

        /// Pads the message and returns the digest.
        public mutating func finalize() -> SHA256Digest {
            let bitLength = messageByteCount &* 8
            var tail = pending
            tail.append(0x80)
            while tail.count % 64 != 56 {
                tail.append(0)
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
            }
            for blockStart in stride(from: 0, to: tail.count, by: 64) {
                compress(Array(tail[blockStart..<(blockStart + 64)]))
            }
            pending = []

            var bytes: [UInt8] = []
            bytes.reserveCapacity(SHA256Digest.byteCount)
            for word in state {
                bytes.append(UInt8(truncatingIfNeeded: word >> 24))
                bytes.append(UInt8(truncatingIfNeeded: word >> 16))
                bytes.append(UInt8(truncatingIfNeeded: word >> 8))
                bytes.append(UInt8(truncatingIfNeeded: word))
            }
            guard let digest = SHA256Digest(bytes: bytes) else {
                preconditionFailure("SHA-256 must produce exactly \(SHA256Digest.byteCount) bytes")
            }
            return digest
        }

        private mutating func compress(_ block: [UInt8]) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let base = index * 4
                schedule[index] =
                    UInt32(block[base]) << 24
                    | UInt32(block[base + 1]) << 16
                    | UInt32(block[base + 2]) << 8
                    | UInt32(block[base + 3])
            }
            for index in 16..<64 {
                let previous15 = schedule[index - 15]
                let previous2 = schedule[index - 2]
                let sigma0 =
                    rotateRight(previous15, 7) ^ rotateRight(previous15, 18) ^ (previous15 >> 3)
                let sigma1 =
                    rotateRight(previous2, 17) ^ rotateRight(previous2, 19) ^ (previous2 >> 10)
                schedule[index] =
                    schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]

            for index in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choose = (e & f) ^ (~e & g)
                let temporary1 = h &+ sum1 &+ choose &+ TestSHA256.roundConstants[index]
                    &+ schedule[index]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sum0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }

            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        private func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
            (value >> count) | (value << (32 - count))
        }
    }

    /// The 64 SHA-256 round constants, from FIPS 180-4.
    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
