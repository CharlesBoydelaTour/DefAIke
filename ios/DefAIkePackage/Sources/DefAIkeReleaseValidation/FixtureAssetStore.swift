import DefAIkeDomain

// The one thing fixture-catalog verification reaches out for: the bytes already on
// disk under a catalogued asset path.
//
// The seam is read-only by construction, and that is the point of the task rather than
// an incidental restriction. There is no member that creates, writes, renders,
// downloads, converts, or regenerates an asset, and none that produces an expected
// result. A catalogued fixture whose asset is absent therefore has exactly one
// outcome available to it — a finding — because nothing in this module can manufacture
// the bytes or the expected output that would make it pass.
//
// No default implementation exists here. A tool that has not been given a store cannot
// verify anything, rather than verifying against something this module chose.

/// What a store found at one catalogued asset path.
///
/// ``symbolicLink`` and ``other`` are representable so verification can refuse them by
/// name. A fixture asset is fixed bytes; a link can point at different bytes than the
/// ones the catalog was signed over.
public enum FixtureAssetKind: Hashable, Sendable {
    /// A regular file of exactly this many bytes.
    case file(byteCount: UInt64)
    /// A directory.
    case directory
    /// A symbolic link, whatever it points at.
    case symbolicLink
    /// Anything else: a socket, a device, a named pipe.
    case other
}

/// Whether streaming should keep reading.
///
/// Reading stops as soon as an asset runs past the byte count its catalog entry
/// declares, so a mutated asset cannot make verification read unbounded bytes.
public enum FixtureAssetReadDisposition: Hashable, Sendable {
    case proceed
    case stop
}

/// Why a catalogued asset's bytes could not be reached.
///
/// Three structural outcomes, no framework error and no absolute path. How each maps to
/// a verification finding belongs to the verifier, not to the store.
public enum FixtureAssetFault: Error, Equatable, Sendable {
    /// Nothing exists at that path.
    case assetMissing
    /// The entry exists but its bytes could not be read.
    case assetUnreadable
    /// The store itself is unavailable.
    case storeUnavailable
}

/// Reads the immutable assets of one Release Fixture Suite.
///
/// Paths are canonical by type, so a traversal string cannot reach a store. Reads are
/// streaming because a fixture suite is not something verification loads into memory,
/// and chunk boundaries never change what is hashed.
public protocol FixtureAssetReading: Sendable {
    /// What exists at one catalogued path inside `suite`.
    func kind(
        at path: CanonicalRelativePath,
        in suite: ArtifactID
    ) throws(FixtureAssetFault) -> FixtureAssetKind

    /// Streams one asset's bytes in order.
    ///
    /// Reading stops early when `sink` returns ``FixtureAssetReadDisposition/stop``.
    func readAsset(
        at path: CanonicalRelativePath,
        in suite: ArtifactID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> FixtureAssetReadDisposition
    ) throws(FixtureAssetFault) -> Void
}
