import DefAIkeDomain
import Foundation

// Step 1 of the fixed verification order: parse the bounded manifest.
//
// Bounded means three things here, and all three are checked before anything trusts a
// field:
//
//   * size — the active Bundle Verification Policy carries the manifest ceiling, so
//     the limit is an approved value rather than a constant in this file;
//   * shape — a strict structural scan refuses a document that repeats a key in any
//     object, nests too deeply, or is not well-formed UTF-8 JSON; and
//   * schema — decoding runs the domain's validating initializers, so a manifest that
//     names the wrong checkpoint, a non-FP16 format, a duplicate artifact path, or a
//     zero-byte artifact cannot become a value at all.
//
// The bytes are kept as they were read. Nothing here re-encodes the decoded manifest,
// because the signature covers those exact bytes (Requirement 10.6).

/// A candidate manifest, its exact bytes' digest, and the byte count that was read.
public struct ParsedModelBundleManifest: Hashable, Sendable {
    public let manifest: ModelBundleManifest

    /// Digest of the exact bytes that were parsed, which is what the signature covers
    /// and what an activation receipt records.
    public let manifestDigest: SHA256Digest

    public let manifestByteCount: UInt64
}

/// Parses one candidate Model Bundle manifest under the active policy's ceiling.
public enum ModelBundleManifestParser {
    /// Parses `manifestBytes` for `bundle`.
    ///
    /// The returned value proves only that the manifest is well-formed, schema-valid,
    /// internally consistent, and self-describing as `bundle`. It says nothing about
    /// the signature or the artifact tree; those are separate steps.
    public static func parse(
        _ manifestBytes: [UInt8],
        for bundle: ModelBundleID,
        policy: BundleVerificationPolicy
    ) throws(ModelBundleVerificationError) -> ParsedModelBundleManifest {
        let byteCount = UInt64(manifestBytes.count)
        let ceiling = policy.maximumManifestByteCount.value
        guard byteCount <= ceiling else {
            throw ModelBundleVerificationError.manifestTooLarge(
                ceiling: ceiling,
                found: byteCount
            )
        }

        do {
            try CanonicalJSONScan.validate(manifestBytes)
        } catch {
            throw scanFinding(error)
        }

        let manifest: ModelBundleManifest
        do {
            manifest = try JSONDecoder().decode(
                ModelBundleManifest.self,
                from: Data(manifestBytes)
            )
        } catch {
            throw decodeFinding(error)
        }

        guard manifest.bundleID == bundle else {
            throw ModelBundleVerificationError.manifestBundleMismatch(
                requested: bundle,
                declared: manifest.bundleID
            )
        }
        try requireDisjointArtifactPaths(manifest.artifacts)

        return ParsedModelBundleManifest(
            manifest: manifest,
            manifestDigest: StreamingSHA256.digest(of: manifestBytes),
            manifestByteCount: byteCount
        )
    }

    // MARK: Declared-path geometry

    /// Refuses a manifest in which one declared artifact path contains another.
    ///
    /// The domain manifest already rejects a repeated path. Containment is the other
    /// way a path can be declared twice: with both `artifacts/model.mlmodelc` and
    /// `artifacts/model.mlmodelc/weights` declared, the weight bytes would be covered
    /// by two digest records, and a tree walk could not tell whether the inner record
    /// replaces or duplicates part of the outer one.
    private static func requireDisjointArtifactPaths(
        _ artifacts: [ArtifactDigestRecord]
    ) throws(ModelBundleVerificationError) {
        let ordered = artifacts.sorted {
            $0.path.rawValue.utf8.lexicographicallyPrecedes($1.path.rawValue.utf8)
        }
        for (offset, outer) in ordered.enumerated() {
            let prefix = outer.path.rawValue + "/"
            for inner in ordered[(offset + 1)...] where inner.path.rawValue.hasPrefix(prefix) {
                throw ModelBundleVerificationError.overlappingDeclaredArtifacts(
                    outer: outer.path,
                    inner: inner.path
                )
            }
        }
    }

    // MARK: Finding mapping

    private static func scanFinding(_ fault: JSONScanFault) -> ModelBundleVerificationError {
        switch fault {
        case .notUTF8:
            return .manifestNotUTF8
        case let .malformed(byteOffset):
            return .manifestNotWellFormedJSON(byteOffset: byteOffset)
        case let .duplicateKey(key):
            return .manifestDuplicateKey(key)
        case let .tooDeep(maximumDepth):
            return .manifestTooDeeplyNested(maximumDepth: maximumDepth)
        }
    }

    /// Reduces a decoding failure to one bounded finding.
    ///
    /// A schema violation surfaces as itself: the domain's validating initializers
    /// attach the `ArtifactSchemaError` as the underlying error, and that error already
    /// names the offending field. Anything else is reported as a field position only,
    /// so no decoder-generated message reaches an audit record.
    private static func decodeFinding(_ error: any Error) -> ModelBundleVerificationError {
        if let schema = error as? ArtifactSchemaError {
            return .manifestRejectedBySchema(schema)
        }
        guard let decoding = error as? DecodingError else {
            return .manifestFieldNotDecodable(field: "manifest")
        }
        switch decoding {
        case let .dataCorrupted(context):
            if let schema = context.underlyingError as? ArtifactSchemaError {
                return .manifestRejectedBySchema(schema)
            }
            return .manifestFieldNotDecodable(field: fieldName(context.codingPath))
        case let .keyNotFound(key, context):
            return .manifestFieldNotDecodable(field: fieldName(context.codingPath + [key]))
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return .manifestFieldNotDecodable(field: fieldName(context.codingPath))
        @unknown default:
            return .manifestFieldNotDecodable(field: "manifest")
        }
    }

    private static func fieldName(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "manifest" }
        let joined = codingPath
            .map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }
            .joined(separator: ".")
        return "manifest.\(joined)"
    }
}
