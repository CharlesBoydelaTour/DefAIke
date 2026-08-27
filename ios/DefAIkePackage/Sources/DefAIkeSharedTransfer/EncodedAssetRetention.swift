import DefAIkeDomain
import Foundation

// Copying a provider's file into protected app-controlled storage.
//
// This is the one place encoded image bytes enter DefAIke. Requirements 2.9 through 2.11
// require a byte-for-byte identical copy of whatever representation the source exposed,
// with a preservation status that is conservative about what that representation was.
// Requirements 2.12 and 2.13 require the *identical* retained sequence to reach the Input
// Validator and, where the capability is enabled, the Provenance Analyzer.
//
// Four rules make that structural rather than careful:
//
//   * The source is opened for reading only and is never written, truncated, moved, or
//     removed. The provider owns its temporary representation; DefAIke borrows it.
//   * The copy is streamed in bounded chunks and hashed in the same pass, so the whole
//     representation is never materialized and the digest describes the bytes that were
//     actually written.
//   * The status is *derived* from the basis rather than passed alongside it, so a caller
//     cannot record `originalBytes` from a basis that only establishes a current
//     representation.
//   * The result is a handle. Nothing here returns image bytes, so the two downstream
//     consumers necessarily read the same immutable object rather than two copies that
//     could diverge.

/// Why a retention attempt did not produce a handle.
///
/// Deliberately not an ``AnalysisError``: how a retention failure is reported depends on
/// where it happened. A provider read that fails before any byte is held starts no session
/// at all, whereas the same failure while staging a consented Share handoff ends a staged
/// attempt. The ingest adapters own that mapping; this type only reports what went wrong.
public enum EncodedAssetRetentionError: Error, Hashable, Sendable {
    /// The provider's representation could not be opened, measured, or read to its end.
    case sourceUnreadable

    /// The provider exposed an empty representation. Zero bytes are not an analyzable
    /// image, and accepting one would let an empty copy pass as preserved bytes.
    case emptySource

    /// The copy ended before the source's measured length was reached.
    ///
    /// Carries both lengths so a caller can record what disagreed. An incomplete copy is
    /// never finalized, so no handle to a short object can exist.
    case incompleteCopy(expectedByteCount: UInt64, copiedByteCount: UInt64)

    /// The user cancelled while the copy was in flight.
    case cancelled

    /// The store refused or failed. The caller's stage decides what that means; a
    /// ``EphemeralStoreError/capacityExceeded(scope:)`` is a `resource-limit` condition.
    case store(EphemeralStoreError)
}

/// Streams provider representations into protected, app-controlled ephemeral storage.
///
/// Holds no state between calls: each retention creates its own object, and a failed
/// retention removes what it created before returning.
public struct EncodedAssetRetainer: Sendable {
    /// Bytes read and written per pass.
    ///
    /// A structural I/O buffer bound, not an approved Resource Budget value: it changes how
    /// many passes a copy takes, never how large a copy is allowed to be. The finalized
    /// bytes, byte count, and digest are identical for every chunk size.
    public static let defaultChunkSizeInBytes = 64 * 1024

    private let store: any EphemeralFileStoring
    private let chunkSizeInBytes: Int

    /// Creates a retainer.
    ///
    /// `chunkSizeInBytes` is clamped to at least one byte so a misconfigured value cannot
    /// turn the copy loop into a nonterminating read of zero-length chunks.
    public init(
        store: any EphemeralFileStoring,
        chunkSizeInBytes: Int = EncodedAssetRetainer.defaultChunkSizeInBytes
    ) {
        self.store = store
        self.chunkSizeInBytes = max(1, chunkSizeInBytes)
    }

    // MARK: - Retention

    /// Streams the file at `source` into a fresh protected object owned by `scope`.
    ///
    /// The returned receipt carries the byte count and digest measured during the copy.
    /// On any failure the object is removed before returning, so a caller never has to
    /// distinguish "failed" from "failed and left something behind".
    ///
    /// Use this for transfer staging, where the ticket is assembled by the caller. Session
    /// ingest uses ``retainAsset(ofFileAt:route:for:basis:contentTypeHint:protection:)``,
    /// which additionally produces the handle downstream stages consume.
    public func retainCopy(
        ofFileAt source: URL,
        into scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EncodedAssetRetentionError) -> EphemeralWriteReceipt {
        let expectedByteCount = try Self.measuredByteCount(ofFileAt: source)
        guard expectedByteCount > 0 else { throw .emptySource }

        let key: EphemeralStorageKey
        do {
            key = try await store.create(in: scope, protection: protection)
        } catch {
            throw .store(error)
        }

        do {
            try await copyStream(from: source, to: key, expecting: expectedByteCount)
        } catch {
            // Nothing partial survives a failed retention. Cleanup is idempotent, so a
            // caller that also cleans up on its own error path is harmless.
            try await discard(scope, after: error)
        }

        do {
            return try await store.finalize(key)
        } catch {
            try await discard(scope, after: .store(error))
        }
    }

    /// Removes `scope`'s material and rethrows `error`.
    ///
    /// Returns `Never` so a caller cannot forget the rethrow and continue with a scope
    /// whose bytes were just deleted.
    private func discard(
        _ scope: EphemeralStorageScope,
        after error: EncodedAssetRetentionError
    ) async throws(EncodedAssetRetentionError) -> Never {
        _ = try? await discardIncompleteCopy(in: scope, reason: Self.cleanupReason(for: error))
        throw error
    }

    /// Streams the file at `source` into a fresh session-owned object and returns the
    /// accepted ingest.
    ///
    /// `basis` is the evidence for what the source actually exposed, and the recorded
    /// ``BytePreservationStatus`` is the most conservative status that basis supports. The
    /// status is not a parameter: there is no way to ask for `originalBytes` without a
    /// basis that establishes it (Requirements 2.9 through 2.11).
    public func retainAsset(
        ofFileAt source: URL,
        route: InputRoute,
        for sessionID: AnalysisSessionID,
        basis: PreservationBasis,
        contentTypeHint: ContentTypeHint?,
        protection: FileProtectionLevel
    ) async throws(EncodedAssetRetentionError) -> ImportedEncodedAsset {
        let receipt = try await retainCopy(
            ofFileAt: source,
            into: .session(sessionID),
            protection: protection
        )
        guard
            let handle = EncodedAssetHandle(sessionID: sessionID, receipt: receipt),
            let asset = ImportedEncodedAsset(
                route: route,
                handle: handle,
                preservationStatus: basis.mostConservativeStatus,
                preservationBasis: basis,
                contentTypeHint: contentTypeHint
            )
        else {
            // Unreachable: an empty source is rejected before the copy starts, the scope is
            // this session's, and a basis always supports its own most conservative status.
            // Reaching it would mean the store finalized something that does not describe
            // the object, so it fails closed and removes the material.
            _ = try? await discardIncompleteCopy(in: .session(sessionID), reason: .errorTerminated)
            throw .store(.storeUnavailable)
        }
        return asset
    }

    /// Removes anything a retention left in `scope`, complete or not.
    ///
    /// Idempotent by contract: a scope that is already empty removes nothing and still
    /// succeeds, so this is safe on a startup path, after an interruption, and after a
    /// previous cleanup of the same scope (Property 25).
    @discardableResult
    public func discardIncompleteCopy(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EncodedAssetRetentionError) -> EphemeralDeletionReceipt {
        do {
            return try await store.deleteAll(in: scope, reason: reason)
        } catch {
            throw .store(error)
        }
    }

    // MARK: - Streaming

    private func copyStream(
        from source: URL,
        to key: EphemeralStorageKey,
        expecting expectedByteCount: UInt64
    ) async throws(EncodedAssetRetentionError) {
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            throw .sourceUnreadable
        }
        defer { try? reader.close() }

        var copiedByteCount: UInt64 = 0
        while true {
            // Cancellation is checked at every chunk boundary, so a cancelled copy stops
            // within one buffer rather than after the whole representation.
            guard !Task.isCancelled else { throw .cancelled }

            let chunk: Data?
            do {
                chunk = try reader.read(upToCount: chunkSizeInBytes)
            } catch {
                throw .sourceUnreadable
            }
            guard let chunk, !chunk.isEmpty else { break }

            do {
                try await store.append(Array(chunk), to: key)
            } catch {
                throw .store(error)
            }
            copiedByteCount += UInt64(chunk.count)
        }

        guard copiedByteCount == expectedByteCount else {
            throw .incompleteCopy(
                expectedByteCount: expectedByteCount,
                copiedByteCount: copiedByteCount
            )
        }
    }

    /// The source's length, without reading or modifying its contents.
    ///
    /// Reads the file's attributes only: no byte of the representation is opened, copied,
    /// or hashed. That is what lets an ingest route reserve headroom for a copy it has not
    /// started yet, so an oversized representation is refused before any byte is read
    /// rather than part way through (Requirement 11.8).
    public static func measuredByteCount(
        ofFileAt source: URL
    ) throws(EncodedAssetRetentionError) -> UInt64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
            let size = attributes[.size] as? NSNumber,
            attributes[.type] as? FileAttributeType == FileAttributeType.typeRegular
        else {
            throw .sourceUnreadable
        }
        return size.uint64Value
    }

    /// The cleanup reason a failed retention removes its material under.
    ///
    /// Only selects which approved deadline the removal is audited against; the removal
    /// itself is immediate in every case.
    private static func cleanupReason(
        for error: EncodedAssetRetentionError
    ) -> SessionCleanupReason {
        switch error {
        case .cancelled: .cancelled
        case .sourceUnreadable, .emptySource, .incompleteCopy, .store: .interrupted
        }
    }
}
