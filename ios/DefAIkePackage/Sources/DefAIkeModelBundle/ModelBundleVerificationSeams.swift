import DefAIkeDomain

// The two things this module reaches out for, and nothing else.
//
// Verification is a pure decision over three inputs: the bytes of a candidate tree,
// the approved Bundle Verification Policy, and the result of executing the policy's
// signature algorithm. The first and third arrive through the seams below, so the
// verifier itself touches no file system, no cryptographic key store, and no network.
//
// Neither seam has a default implementation in this module. That is the point: a
// build that has not been given key material or an algorithm implementation cannot
// verify anything, instead of falling back to something this module chose
// (Requirements 10.6 and 10.8).

// MARK: - Reading a candidate tree

/// One entry found while enumerating a candidate bundle's tree.
///
/// The path is the raw string the store reports, before canonicalization, so a
/// noncanonical or traversing path is a detectable finding rather than something the
/// enumeration has already normalized away.
public struct BundleTreeEntry: Hashable, Sendable {
    /// What the store found at this path.
    ///
    /// ``symbolicLink`` and ``other`` are representable so that verification can
    /// refuse them by name. A store must not silently resolve or skip them.
    public enum Kind: Hashable, Sendable {
        /// A regular file of exactly this many bytes.
        case file(byteCount: UInt64)
        /// A directory.
        case directory
        /// A symbolic link, whatever it points at.
        case symbolicLink
        /// Anything else: a socket, a device, a named pipe.
        case other
    }

    /// Path relative to the bundle root, exactly as the store reports it.
    public let rawPath: String

    public let kind: Kind

    public init(rawPath: String, kind: Kind) {
        self.rawPath = rawPath
        self.kind = kind
    }
}

/// Whether stream hashing should keep reading.
///
/// A verifier stops as soon as content runs past the byte count its manifest
/// declares, so a candidate cannot make verification read unbounded bytes.
public enum BundleReadDisposition: Hashable, Sendable {
    case proceed
    case stop
}

/// Why a candidate's bytes could not be reached.
///
/// Three structural outcomes, no framework error and no absolute path. How each maps
/// to a verification finding depends on what was being read, so the mapping belongs
/// to the verifier rather than to the store.
public enum BundleContentFault: Error, Equatable, Sendable {
    /// Nothing exists at that path.
    case entryMissing
    /// The entry exists but its bytes could not be read.
    case entryUnreadable
    /// The store itself is unavailable.
    case storeUnavailable
}

/// Reads one locally installed candidate Model Bundle.
///
/// Deliberately absent: any member that resolves a link, creates, writes, moves, or
/// deletes anything, and any member that takes a path this module has not already
/// validated as canonical. Reads are streaming because a Core ML weight blob is not
/// something verification loads into memory to hash.
public protocol ModelBundleContentReading: Sendable {
    /// Every entry under the bundle root, recursively, in any order.
    ///
    /// Directories are reported as entries in their own right, so an undeclared empty
    /// directory is visible to a declared-only-contents check.
    func entries(
        in bundle: ModelBundleID
    ) throws(BundleContentFault) -> [BundleTreeEntry]

    /// Streams one file's bytes in order.
    ///
    /// The path is canonical by type, so a traversal string cannot reach the store.
    /// Chunk boundaries never change what is hashed; reading stops early when `sink`
    /// returns ``BundleReadDisposition/stop``.
    func readFile(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> BundleReadDisposition
    ) throws(BundleContentFault) -> Void
}

// MARK: - Executing the approved signature algorithm

/// The result of one signature check.
///
/// ``algorithmUnsupported`` is separate from ``notVerified`` so that a build which
/// cannot execute the approved algorithm fails with that finding instead of looking
/// like a bad signature — and so that it can never look like a pass.
public enum SignatureCheckOutcome: Hashable, Sendable {
    case verified
    case notVerified
    case algorithmUnsupported
}

/// Supplies release public key material and executes exactly one named algorithm.
///
/// Key custody and algorithm execution are the two parts of signature verification
/// this module is not allowed to decide, so they arrive together through one injected
/// seam. The seam is told which algorithm to run and which key to run it under; it
/// chooses neither, and it has no member that reports "trusted" or "revoked" —
/// those answers come from the Bundle Verification Policy.
public protocol BundleSignatureVerifying: Sendable {
    /// Public key material for one key the active policy trusts, or `nil` when this
    /// build carries none.
    ///
    /// `nil` is a fail-closed refusal, never a skipped check. The verifier confirms
    /// the returned material digests to the value the policy records before using it.
    func publicKeyMaterial(for key: SigningKeyID) -> [UInt8]?

    /// Verifies `signature` over `message` using exactly `algorithm`.
    ///
    /// An implementation that does not implement `algorithm` returns
    /// ``SignatureCheckOutcome/algorithmUnsupported``. It must never substitute
    /// another algorithm and must never return ``SignatureCheckOutcome/verified``
    /// for one it did not execute.
    func verify(
        signature: [UInt8],
        over message: [UInt8],
        using algorithm: SignatureAlgorithm,
        publicKeyMaterial: [UInt8]
    ) -> SignatureCheckOutcome
}
