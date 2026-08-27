import Foundation
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Bounded manifest parsing: the size ceiling comes from the active policy, the shape
/// checks come from the structural scan, and the field rules come from the domain's
/// validating initializers.
@Suite("Model Bundle manifest parsing")
struct ModelBundleManifestParsingTests {
    private func parse(
        _ bytes: [UInt8],
        bundle: ModelBundleID = Sample.bundle(),
        policy: BundleVerificationPolicy
    ) -> Result<ParsedModelBundleManifest, ModelBundleVerificationError> {
        do {
            return .success(try ModelBundleManifestParser.parse(bytes, for: bundle, policy: policy))
        } catch {
            return .failure(error)
        }
    }

    private func finding(
        _ bytes: [UInt8],
        bundle: ModelBundleID = Sample.bundle(),
        policy: BundleVerificationPolicy
    ) -> ModelBundleVerificationError? {
        switch parse(bytes, bundle: bundle, policy: policy) {
        case .success: return nil
        case let .failure(error): return error
        }
    }

    @Test("A valid manifest parses and reports the digest of the exact bytes read")
    func validManifestParses() throws {
        let assembled = try BundleAssembler.standard()
        let parsed = try ModelBundleManifestParser.parse(
            assembled.manifestBytes,
            for: assembled.bundleID,
            policy: assembled.policy
        )
        #expect(parsed.manifest == assembled.manifest)
        #expect(parsed.manifestByteCount == UInt64(assembled.manifestBytes.count))
        #expect(parsed.manifestDigest == StreamingSHA256.digest(of: assembled.manifestBytes))
    }

    @Test("Every manifest field survives an encode and parse round trip")
    func roundTripPreservesEveryField() throws {
        let assembled = try BundleAssembler.standard()
        let parsed = try ModelBundleManifestParser.parse(
            assembled.manifestBytes,
            for: assembled.bundleID,
            policy: assembled.policy
        )
        let manifest = parsed.manifest
        #expect(manifest.modelIdentity == RequiredPixelModel.identity)
        #expect(manifest.modelFormat.programKind == .mlProgram)
        #expect(manifest.modelFormat.computePrecision == .float16)
        #expect(manifest.modelFormat.minimumOS == .iOS17)
        #expect(manifest.outputContract.featureName.value == ModelOutputContract.requiredFeatureName)
        #expect(manifest.componentVersions == Sample.componentVersions())
        #expect(manifest.compatibility.requiredCapabilities.contains(.pixelAnalysis))
        #expect(
            manifest.upstreamBoundaryMetadata.rawLogitValue
                == UpstreamBoundaryMetadata.requiredValue
        )
        #expect(manifest.declaredPaths.count == 3)
    }

    @Test("A manifest above the policy ceiling is refused before any field is trusted")
    func manifestCeilingIsPolicySupplied() throws {
        let assembled = try BundleAssembler.standard()
        let ceiling = UInt64(assembled.manifestBytes.count - 1)
        let tightened = try BundleAssembler.standard(manifestByteCeiling: ceiling).policy

        #expect(
            finding(assembled.manifestBytes, policy: tightened)
                == .manifestTooLarge(
                    ceiling: ceiling,
                    found: UInt64(assembled.manifestBytes.count)
                )
        )
        // The same bytes pass under a policy whose ceiling admits them: the limit is the
        // policy's, not this module's.
        #expect(finding(assembled.manifestBytes, policy: assembled.policy) == nil)
    }

    @Test("A manifest that repeats a key is refused")
    func duplicateKeyRefused() throws {
        let assembled = try BundleAssembler.standard()
        let text = String(decoding: assembled.manifestBytes, as: UTF8.self)
        let spliced = #"{"bundleID":"bundle.other","# + text.dropFirst()

        #expect(
            finding(Array(spliced.utf8), policy: assembled.policy)
                == .manifestDuplicateKey("bundleID")
        )
    }

    @Test("A manifest that is not valid UTF-8 is refused")
    func invalidUTF8Refused() throws {
        let assembled = try BundleAssembler.standard()
        var bytes = assembled.manifestBytes
        bytes[bytes.count / 2] = 0xFF
        #expect(finding(bytes, policy: assembled.policy) == .manifestNotUTF8)
    }

    @Test("A truncated manifest is refused as malformed JSON")
    func truncatedManifestRefused() throws {
        let assembled = try BundleAssembler.standard()
        let truncated = Array(assembled.manifestBytes.dropLast(20))
        guard case .manifestNotWellFormedJSON = finding(truncated, policy: assembled.policy) else {
            Issue.record("expected a malformed-JSON finding")
            return
        }
    }

    @Test("A manifest naming the wrong checkpoint is refused by the schema")
    func wrongCheckpointRefusedBySchema() throws {
        let assembled = try BundleAssembler.standard()
        let text = String(decoding: assembled.manifestBytes, as: UTF8.self)
            .replacingOccurrences(
                of: RequiredPixelModel.checkpointIdentifier,
                with: "Thermostatic/some-other-detector-2027-01"
            )
        guard case let .manifestRejectedBySchema(schema) =
            finding(Array(text.utf8), policy: assembled.policy)
        else {
            Issue.record("expected a schema finding")
            return
        }
        guard case let .fixedValueMismatch(field, _, _) = schema else {
            Issue.record("expected a fixed-value mismatch, found \(schema)")
            return
        }
        #expect(field == "manifest.modelIdentity")
    }

    @Test("A manifest missing a required field names the field and no decoder text")
    func missingFieldNamesTheField() throws {
        let assembled = try BundleAssembler.standard()
        var object = try JSONSerialization.jsonObject(
            with: Data(assembled.manifestBytes)
        ) as! [String: Any]
        object.removeValue(forKey: "signingKey")
        let bytes = Array(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(
            finding(bytes, policy: assembled.policy)
                == .manifestFieldNotDecodable(field: "manifest.signingKey")
        )
    }

    @Test("A manifest describing another bundle is refused")
    func bundleIdentityMustMatch() throws {
        let assembled = try BundleAssembler.standard(
            declaredBundleID: Sample.bundle("bundle.other")
        )
        #expect(
            finding(
                assembled.manifestBytes,
                bundle: Sample.bundle(),
                policy: assembled.policy
            )
                == .manifestBundleMismatch(
                    requested: Sample.bundle(),
                    declared: Sample.bundle("bundle.other")
                )
        )
    }

    @Test("One declared artifact path may not contain another")
    func overlappingDeclaredPathsRefused() throws {
        let assembled = try BundleAssembler.standard(artifactOverrides: { records in
            records + [
                ArtifactDigestRecord(
                    path: Sample.path("\(BundleAssembler.modelTreePath)/coremldata.bin"),
                    kind: .file,
                    byteCount: 12,
                    digest: Sample.digest("c")
                )
            ]
        })
        #expect(
            finding(assembled.manifestBytes, policy: assembled.policy)
                == .overlappingDeclaredArtifacts(
                    outer: Sample.path(BundleAssembler.modelTreePath),
                    inner: Sample.path("\(BundleAssembler.modelTreePath)/coremldata.bin")
                )
        )
    }

    @Test("Sibling declared paths sharing a prefix string are not overlapping")
    func siblingPrefixesAreNotOverlapping() throws {
        let assembled = try BundleAssembler.standard(artifactOverrides: { records in
            records + [
                ArtifactDigestRecord(
                    path: Sample.path("\(BundleAssembler.modelTreePath)-backup"),
                    kind: .file,
                    byteCount: 4,
                    digest: Sample.digest("c")
                )
            ]
        })
        #expect(finding(assembled.manifestBytes, policy: assembled.policy) == nil)
    }

    @Test("Every verification finding maps to one model-load error at the model-load stage")
    func findingsMapToOneClosedCategory() {
        let findings: [ModelBundleVerificationError] = [
            .bundleTreeUnreadable(Sample.bundle()),
            .manifestDuplicateKey("bundleID"),
            .signingKeyRevoked(Sample.signingKey()),
            .artifactDigestMismatch(Sample.path("artifacts/model.mlmodelc")),
            .undeclaredTreeEntry(Sample.path("artifacts/leftover.tmp")),
        ]
        for finding in findings {
            #expect(finding.analysisFault == .analysis(.modelLoadError, stage: .modelLoad))
        }
    }
}
