import DefAIkeTestSupport
import Foundation
import Testing

@testable import DefAIkeDomain

// Tests for the bounded artifact encoding profile and the decoder above it.
//
// Two questions are asked here, and they are separate on purpose:
//
//   * Can a payload that is not a bounded, unambiguous artifact encoding get past the
//     profile? Duplicate keys are the sharp case: a general-purpose decoder resolves
//     them silently, so two readers of the same signed bytes can disagree about a
//     budget or a trusted key while both believe they read the signed artifact.
//   * When a field is absent, null, mistyped, or names semantics this build does not
//     implement, does anything substitute a value? Nothing may, which is why the
//     no-default sweep drops every top-level key of several real artifacts in turn.
//
// The limits used here are test values. `ArtifactEncodingLimits` has no default
// initializer, so a payload ceiling has to be stated at every call site; in shipping
// code it comes from the approved Bundle Verification Policy.

extension ArtifactEncodingLimits {
    /// Generous test limits. Not an approved release value.
    static func testing(
        maximumBytes: UInt64 = 1 << 20,
        depth: Int = ArtifactEncodingLimits.defaultMaximumNestingDepth,
        objectEntries: Int = ArtifactEncodingLimits.defaultMaximumObjectEntryCount,
        arrayElements: Int = ArtifactEncodingLimits.defaultMaximumArrayElementCount,
        stringScalars: Int = ArtifactEncodingLimits.defaultMaximumStringScalarCount,
        numberLength: Int = ArtifactEncodingLimits.defaultMaximumNumberTokenLength
    ) -> ArtifactEncodingLimits {
        ArtifactEncodingLimits(
            maximumByteCount: Sample.byteCount(maximumBytes),
            maximumNestingDepth: depth,
            maximumObjectEntryCount: objectEntries,
            maximumArrayElementCount: arrayElements,
            maximumStringScalarCount: stringScalars,
            maximumNumberTokenLength: numberLength
        )
    }
}

@Suite("Bounded artifact encoding profile")
struct ArtifactEncodingProfileTests {
    private func report(
        _ json: String,
        limits: ArtifactEncodingLimits = .testing()
    ) throws -> ArtifactEncodingReport {
        try ArtifactEncodingProfile.validate(Array(json.utf8), limits: limits)
    }

    private func error(
        _ json: String,
        limits: ArtifactEncodingLimits = .testing()
    ) -> ArtifactDecodingError? {
        do {
            _ = try ArtifactEncodingProfile.validate(Array(json.utf8), limits: limits)
            return nil
        } catch {
            return error
        }
    }

    private func error(
        bytes: [UInt8],
        limits: ArtifactEncodingLimits = .testing()
    ) -> ArtifactDecodingError? {
        do {
            _ = try ArtifactEncodingProfile.validate(bytes, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    @Test("A payload beyond the supplied ceiling is refused before it is parsed")
    func payloadCeiling() {
        let json = #"{"a":1}"#
        #expect(
            error(json, limits: .testing(maximumBytes: 3))
                == .payloadTooLarge(limitBytes: 3, actualBytes: UInt64(json.utf8.count))
        )
        #expect(error(json, limits: .testing(maximumBytes: UInt64(json.utf8.count))) == nil)
    }

    @Test("An empty payload is not an artifact")
    func emptyPayload() {
        #expect(error(bytes: []) == .emptyPayload)
    }

    @Test("A leading byte order mark is refused")
    func byteOrderMark() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array(#"{"a":1}"#.utf8)
        #expect(
            error(bytes: bytes)
                == .malformedEncoding(byteOffset: 0, reason: "leading byte order mark")
        )
    }

    @Test("Only an object may be the top-level value")
    func topLevelMustBeAnObject() {
        for json in ["[]", #""text""#, "1", "true", "null", #"[{"a":1}]"#] {
            #expect(error(json) == .topLevelValueNotAnObject(byteOffset: 0))
        }
        #expect(error("{}") == nil)
    }

    @Test("Content after the top-level value is refused")
    func trailingContent() {
        #expect(error("{} {}") == .trailingContentError(byteOffset: 3))
        #expect(error(#"{"a":1}x"#) == .trailingContentError(byteOffset: 7))
        #expect(error("  {}  \n") == nil)
    }

    @Test("A duplicate key is refused at the root and at every nesting level")
    func duplicateKeys() {
        #expect(
            error(#"{"budget":1,"budget":2}"#)
                == .duplicateKey(path: "<root>", key: "budget")
        )
        #expect(
            error(#"{"outer":{"key":1,"key":2}}"#)
                == .duplicateKey(path: "outer", key: "key")
        )
        #expect(
            error(#"{"list":[{"key":1,"key":2}]}"#)
                == .duplicateKey(path: "list[0]", key: "key")
        )
        #expect(error(#"{"a":{"key":1},"b":{"key":2}}"#) == nil)
    }

    @Test("Nesting is bounded and the observed depth is reported")
    func nestingDepth() throws {
        let limits = ArtifactEncodingLimits.testing(depth: 4)
        let deepest = try report(
            String(decoding: CanonicalArtifactPayload.nested(depth: 4), as: UTF8.self),
            limits: limits
        )
        #expect(deepest.observedNestingDepth == 4)

        let tooDeep = CanonicalArtifactPayload.nested(depth: 5)
        guard case let .nestingTooDeep(limit, _)? = error(bytes: tooDeep, limits: limits) else {
            Issue.record("expected the depth ceiling to refuse a deeper payload")
            return
        }
        #expect(limit == 4)
    }

    @Test("Nesting through arrays counts toward the same ceiling")
    func nestingThroughArrays() {
        let limits = ArtifactEncodingLimits.testing(depth: 2)
        #expect(error(#"{"a":[1,2]}"#, limits: limits) == nil)
        guard case .nestingTooDeep? = error(#"{"a":[[1]]}"#, limits: limits) else {
            Issue.record("expected an array nested inside an array to exceed depth 2")
            return
        }
    }

    @Test("Container, string, and number ceilings are enforced")
    func structuralCeilings() {
        #expect(
            error(#"{"a":1,"b":2,"c":3}"#, limits: .testing(objectEntries: 2))
                == .structuralBoundExceeded(path: "<root>", bound: .objectEntries, limit: 2)
        )
        #expect(
            error(#"{"a":[1,2,3]}"#, limits: .testing(arrayElements: 2))
                == .structuralBoundExceeded(path: "a", bound: .arrayElements, limit: 2)
        )
        #expect(
            error(#"{"a":"abcd"}"#, limits: .testing(stringScalars: 3))
                == .structuralBoundExceeded(path: "a", bound: .stringScalars, limit: 3)
        )
        #expect(
            error(#"{"a":1234567}"#, limits: .testing(numberLength: 3))
                == .structuralBoundExceeded(path: "a", bound: .numberTokenLength, limit: 3)
        )
    }

    @Test("Invalid UTF-8 inside a string is refused with its offset")
    func invalidUTF8InString() {
        // 0xC3 begins a two-byte sequence; 0x28 is not a continuation byte.
        let bytes: [UInt8] = Array(#"{"a":""#.utf8) + [0xC3, 0x28] + Array(#""}"#.utf8)
        #expect(error(bytes: bytes) == .invalidUTF8(byteOffset: 7))

        // An overlong encoding of "/" must not be accepted as a second spelling.
        let overlong: [UInt8] = Array(#"{"a":""#.utf8) + [0xC0, 0xAF] + Array(#""}"#.utf8)
        #expect(error(bytes: overlong) == .invalidUTF8(byteOffset: 6))

        // A surrogate encoded directly in UTF-8 is not a scalar.
        let surrogate: [UInt8] = Array(#"{"a":""#.utf8) + [0xED, 0xA0, 0x80] + Array(#""}"#.utf8)
        #expect(error(bytes: surrogate) == .invalidUTF8(byteOffset: 7))
    }

    @Test("Well-formed multi-byte text is accepted")
    func validMultiByteText() throws {
        let accepted = try report(#"{"a":"é 🇬🇧 中"}"#)
        #expect(accepted.topLevelKeys == ["a"])
    }

    @Test("A byte above ASCII outside a string is a structural fault")
    func nonASCIIOutsideString() {
        let bytes: [UInt8] = Array(#"{"a":"#.utf8) + [0xC3, 0xA9] + Array("}".utf8)
        guard case let .malformedEncoding(offset, _)? = error(bytes: bytes) else {
            Issue.record("expected a structural fault outside a string")
            return
        }
        #expect(offset == 5)
    }

    @Test("An unescaped control character is refused")
    func unescapedControlCharacter() {
        let bytes: [UInt8] = Array(#"{"a":""#.utf8) + [0x0A] + Array(#""}"#.utf8)
        guard case let .malformedEncoding(offset, reason)? = error(bytes: bytes) else {
            Issue.record("expected an unescaped control character to be refused")
            return
        }
        #expect(offset == 6)
        #expect(reason.contains("control character"))
    }

    @Test("Escapes are total: known escapes decode, unknown and lone surrogates do not")
    func escapes() throws {
        #expect(try report(#"{"a":"\" \\ \/ \b \f \n \r \t \u0041"}"#).topLevelKeys == ["a"])
        #expect(try report(#"{"a":"\uD83D\uDE00"}"#).topLevelKeys == ["a"])

        for malformed in [
            #"{"a":"\x"}"#,
            #"{"a":"\u00"}"#,
            #"{"a":"\uD83D"}"#,
            #"{"a":"\uDE00"}"#,
            #"{"a":"\uD83D\u0041"}"#,
        ] {
            guard case .malformedEncoding? = error(malformed) else {
                Issue.record("expected \(malformed) to be refused")
                continue
            }
        }
    }

    @Test("Number tokens follow the grammar with no leading zero or plus sign")
    func numberGrammar() throws {
        for accepted in ["0", "-0", "1", "-1.5", "1e10", "1E+10", "2.5e-3", "1390625"] {
            #expect(error(#"{"a":\#(accepted)}"#) == nil, "\(accepted) should be accepted")
        }
        for refused in ["01", "+1", "1.", ".5", "1e", "1e+", "-", "0x10", "1_000", "Infinity"] {
            #expect(error(#"{"a":\#(refused)}"#) != nil, "\(refused) should be refused")
        }
    }

    @Test("Literals must be spelled exactly")
    func literals() {
        #expect(error(#"{"a":true,"b":false,"c":null}"#) == nil)
        for refused in ["tru", "TRUE", "None", "nul"] {
            #expect(error(#"{"a":\#(refused)}"#) != nil, "\(refused) should be refused")
        }
    }

    @Test("Unterminated containers and strings are refused")
    func unterminated() {
        for refused in [#"{"a":1"#, #"{"a""#, #"{"a":"text"#, #"{"a":[1"#, "{"] {
            #expect(error(refused) != nil, "\(refused) should be refused")
        }
    }

    @Test("The report describes the payload that was read")
    func reportContents() throws {
        let json = #"{"schemaVersion":1,"id":"artifact.sample","nested":{"deep":{"x":1}}}"#
        let observed = try report(json)
        #expect(observed.byteCount == UInt64(json.utf8.count))
        #expect(observed.topLevelKeys == ["schemaVersion", "id", "nested"])
        #expect(observed.observedNestingDepth == 3)
    }
}

@Suite("Bounded artifact decoding")
struct BoundedArtifactDecoderTests {
    private let decoder = BoundedArtifactDecoder(limits: .testing())

    /// Decodes a mutated payload and returns the fault it produced.
    ///
    /// Fails the test when the mutation did not apply or when the decoder accepted the
    /// payload, so an assertion can never pass against an unmutated artifact.
    private func fault<Value: Decodable>(
        _ type: Value.Type,
        _ bytes: [UInt8]?,
        using bounded: BoundedArtifactDecoder? = nil
    ) throws -> ArtifactDecodingError {
        let payload = try #require(bytes, "the mutation did not apply")
        let outcome: ArtifactDecodingError?
        do {
            _ = try (bounded ?? decoder).decode(type, from: payload)
            outcome = nil
        } catch {
            outcome = error
        }
        return try #require(outcome, "\(type) accepted the mutated payload")
    }

    @Test("A valid artifact round trips through the bounded decoder")
    func roundTrip() throws {
        let policy = try Sample.lifecyclePolicy()
        let decoded = try decoder.decode(
            DataLifecyclePolicy.self,
            from: CanonicalArtifactPayload.bytes(policy)
        )
        #expect(decoded == policy)
    }

    @Test("The payload ceiling comes from the approved verification policy")
    func ceilingFromPolicy() throws {
        let verification = try Sample.verificationPolicy()
        let bounded = BoundedArtifactDecoder(manifestLimitsFrom: verification)
        #expect(bounded.limits.maximumByteCount == verification.maximumManifestByteCount)

        // The ceiling that refuses an oversized payload is the policy's number, not a
        // compiled-in size.
        let ceiling = Int(verification.maximumManifestByteCount.value)
        let oversized = Array(#"{"a":""#.utf8)
            + Array(repeating: UInt8(ascii: "x"), count: ceiling)
            + Array(#""}"#.utf8)
        guard case let .payloadTooLarge(limit, actual) = try fault(
            DataLifecyclePolicy.self,
            oversized,
            using: bounded
        ) else {
            Issue.record("expected the policy ceiling to refuse an oversized payload")
            return
        }
        #expect(limit == verification.maximumManifestByteCount.value)
        #expect(actual == UInt64(oversized.count))
    }

    @Test("A duplicate key is refused even though a general-purpose decoder resolves it")
    func duplicateKeyRefused() throws {
        let policy = try Sample.lifecyclePolicy()
        let appended = try CanonicalArtifactPayload.duplicatingTopLevelKey(
            "deadlines",
            in: policy,
            placing: .last
        )
        let duplicated = try #require(appended)

        // A general-purpose decoder resolves the duplicate silently and reports the
        // artifact as if it had read the signed bytes unambiguously. That is exactly why
        // the profile refuses it: which occurrence wins is an implementation detail, so
        // the signature would no longer pin behavior.
        #expect(
            try JSONDecoder().decode(DataLifecyclePolicy.self, from: Data(duplicated)) == policy
        )
        #expect(
            try fault(DataLifecyclePolicy.self, duplicated)
                == .duplicateKey(path: "<root>", key: "deadlines")
        )

        // Placed first instead, the same payload reads as a *different* artifact through
        // the same general-purpose decoder. The profile refuses this one too.
        let prepended = try CanonicalArtifactPayload.duplicatingTopLevelKey(
            "deadlines",
            in: policy,
            placing: .first
        )
        #expect(
            try fault(DataLifecyclePolicy.self, try #require(prepended))
                == .duplicateKey(path: "<root>", key: "deadlines")
        )
    }

    @Test("An absent required field is reported as absent, never defaulted")
    func absentField() throws {
        let evidence = Sample.evidence()
        #expect(
            try fault(
                EvidenceSource.self,
                CanonicalArtifactPayload.removingTopLevelKey("version", from: evidence)
            ) == .missingRequiredField(path: "version")
        )
    }

    @Test("A null required field is reported as null, never defaulted")
    func nullField() throws {
        let evidence = Sample.evidence()
        #expect(
            try fault(
                EvidenceSource.self,
                CanonicalArtifactPayload.nullingTopLevelKey("version", in: evidence)
            ) == .nullRequiredField(path: "version")
        )
    }

    @Test("A mistyped field is reported with the type that was required")
    func mistypedField() throws {
        let evidence = Sample.evidence()
        let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
            "artifact",
            with: 42,
            in: evidence
        )
        guard case let .typeMismatch(path, _) = try fault(EvidenceSource.self, mutated) else {
            Issue.record("expected a type mismatch")
            return
        }
        #expect(path == "artifact")
    }

    @Test("A malformed version is reported as the schema fault it is")
    func malformedVersion() throws {
        let evidence = Sample.evidence()
        for malformed in ["0.0.0", "1.2", "v1.2.3", "1.02.0"] {
            let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
                "version",
                with: malformed,
                in: evidence
            )
            guard case let .schemaViolation(path, error) = try fault(
                EvidenceSource.self,
                mutated
            ) else {
                Issue.record("expected \(malformed) to be a schema violation")
                continue
            }
            #expect(path == "version")
            switch error {
            case .noncanonicalValue, .placeholderValue: break
            default: Issue.record("unexpected schema fault for \(malformed): \(error)")
            }
        }
    }

    @Test("A placeholder value is refused during decoding")
    func placeholderValue() throws {
        let descriptor = ColorSpaceDescriptor(
            identifier: Sample.text(),
            profileDigest: Sample.digest()
        )
        let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
            "identifier",
            with: "TBD",
            in: descriptor
        )
        guard case let .schemaViolation(path, error) = try fault(
            ColorSpaceDescriptor.self,
            mutated
        ) else {
            Issue.record("expected a placeholder to be refused")
            return
        }
        #expect(path == "identifier")
        #expect(error == .placeholderValue(field: "text", value: "TBD"))
    }

    @Test("A nonpositive numeric limit is refused during decoding")
    func nonPositiveLimit() throws {
        let verification = try Sample.verificationPolicy()
        let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
            "maximumManifestByteCount",
            with: 0,
            in: verification
        )
        guard case let .schemaViolation(path, error) = try fault(
            BundleVerificationPolicy.self,
            mutated
        ) else {
            Issue.record("expected a zero ceiling to be refused")
            return
        }
        #expect(path == "maximumManifestByteCount")
        #expect(error == .nonPositiveValue(field: "byteCount", value: "0"))
    }

    @Test("An invalid duration is refused during decoding")
    func invalidDuration() throws {
        let deadline = DataLifecyclePolicy.Deadline(
            reason: .completed,
            deadline: Sample.duration()
        )
        let zeroed = try CanonicalArtifactPayload.replacingTopLevelValue(
            "deadline",
            with: 0,
            in: deadline
        )
        #expect(
            try fault(DataLifecyclePolicy.Deadline.self, zeroed)
                == .schemaViolation(
                    path: "deadline",
                    error: .nonPositiveValue(field: "duration", value: "0ms")
                )
        )

        let overlong = try CanonicalArtifactPayload.replacingTopLevelValue(
            "deadline",
            with: ValidatedDuration.maximumMilliseconds + 1,
            in: deadline
        )
        guard case let .schemaViolation(_, error) = try fault(
            DataLifecyclePolicy.Deadline.self,
            overlong
        ) else {
            Issue.record("expected an overlong deadline to be refused")
            return
        }
        guard case .valueOutOfRange = error else {
            Issue.record("unexpected fault for an overlong deadline: \(error)")
            return
        }
    }

    @Test("An unknown member of a required closed vocabulary is refused, not approximated")
    func unknownClosedVocabularyMember() throws {
        let verification = try Sample.verificationPolicy()
        let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
            "algorithm",
            with: "md5",
            in: verification
        )
        guard case let .valueRejected(path, _) = try fault(
            BundleVerificationPolicy.self,
            mutated
        ) else {
            Issue.record("expected an unknown algorithm to be refused")
            return
        }
        #expect(path == "algorithm")
    }

    @Test("An unknown cleanup reason cannot resolve to a known deadline")
    func unknownCleanupReason() throws {
        let deadline = DataLifecyclePolicy.Deadline(
            reason: .completed,
            deadline: Sample.duration()
        )
        let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
            "reason",
            with: "eventually",
            in: deadline
        )
        guard case let .valueRejected(path, _) = try fault(
            DataLifecyclePolicy.Deadline.self,
            mutated
        ) else {
            Issue.record("expected an unknown cleanup reason to be refused")
            return
        }
        #expect(path == "reason")
    }

    @Test("A noncanonical artifact path is refused")
    func noncanonicalPath() throws {
        let record = Sample.digestRecord()
        for path in ["../escape", "/absolute", "nested/./here", "with space", ""] {
            let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
                "path",
                with: path,
                in: record
            )
            guard case let .valueRejected(field, _) = try fault(
                ArtifactDigestRecord.self,
                mutated
            ) else {
                Issue.record("expected \(path) to be refused")
                continue
            }
            #expect(field == "path")
        }
    }

    @Test("A noncanonical identifier is refused")
    func noncanonicalIdentifier() throws {
        let evidence = Sample.evidence()
        for identifier in ["has space", "tab\tseparated", "ünicode", ""] {
            let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
                "artifact",
                with: identifier,
                in: evidence
            )
            guard case let .valueRejected(path, _) = try fault(EvidenceSource.self, mutated) else {
                Issue.record("expected \(identifier) to be refused")
                continue
            }
            #expect(path == "artifact")
        }
    }

    @Test("A schema version beyond this revision is refused")
    func unsupportedSchemaVersion() throws {
        let policy = try Sample.lifecyclePolicy()
        let mutated = try CanonicalArtifactPayload.replacingTopLevelValue(
            "schemaVersion",
            with: ArtifactSchemaVersion.maximumSupported + 1,
            in: policy
        )
        guard case let .schemaViolation(path, error) = try fault(
            DataLifecyclePolicy.self,
            mutated
        ) else {
            Issue.record("expected an unsupported schema version to be refused")
            return
        }
        #expect(path == "schemaVersion")
        guard case .valueOutOfRange = error else {
            Issue.record("unexpected fault for an unsupported schema version: \(error)")
            return
        }
    }

    @Test("An incomplete total map cannot be decoded into a usable policy")
    func incompleteTotalMap() throws {
        // A lifecycle policy that covers only two cleanup reasons is unbuildable, so the
        // payload is assembled by removing entries from a complete one. Decoding it must
        // fail rather than leave three reasons without a deadline.
        let complete = try Sample.lifecyclePolicy()
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(CanonicalArtifactPayload.bytes(complete))
            ) as? [String: Any]
        )
        let deadlines = try #require(object["deadlines"] as? [Any])
        object["deadlines"] = Array(deadlines.prefix(2))
        let mutated = Array(try JSONSerialization.data(withJSONObject: object))
        guard case let .schemaViolation(_, error) = try fault(
            DataLifecyclePolicy.self,
            mutated
        ) else {
            Issue.record("expected an incomplete deadline map to be refused")
            return
        }
        guard case .missingRequiredEntries = error else {
            Issue.record("unexpected fault for an incomplete deadline map: \(error)")
            return
        }
    }

    @Test("Dropping any required top-level field fails closed, for every artifact")
    func noDefaultIsEverSubstituted() throws {
        try assertEveryFieldRequired(Sample.lifecyclePolicy(), DataLifecyclePolicy.self)
        try assertEveryFieldRequired(
            Sample.extensionExecutionPolicy(),
            ExtensionExecutionPolicy.self
        )
        try assertEveryFieldRequired(Sample.verificationPolicy(), BundleVerificationPolicy.self)
        try assertEveryFieldRequired(
            Sample.resourceBudget(target: .mainApplication),
            ResourceBudget.self
        )
        try assertEveryFieldRequired(Sample.calibrationPolicy(), CalibrationPolicy.self)
        try assertEveryFieldRequired(Sample.capabilityManifest(), ReleaseCapabilityManifest.self)
        try assertEveryFieldRequired(Sample.copyCatalog(), ApprovedVerdictCopyCatalog.self)
        try assertEveryFieldRequired(Sample.preprocessingContract(), PreprocessingContract.self)
        try assertEveryFieldRequired(Sample.manifest(), ModelBundleManifest.self)
    }

    @Test("An unreadable artifact and an invalid one are different findings")
    func unreadableIsNotInvalid() throws {
        let schemaFault = ArtifactSchemaError.placeholderValue(field: "text", value: "TBD")
        let decodeFault = ArtifactDecodingError.schemaViolation(
            path: "identifier",
            error: schemaFault
        )
        // The port vocabulary keeps them apart, because a payload that never formed an
        // artifact value is a different audit finding from an artifact that formed and
        // failed validation.
        #expect(ReleaseArtifactError.undecodable(decodeFault) != .invalid(schemaFault))

        // Every fault names one artifact position, so an audit can point at it.
        #expect(decodeFault.description.contains("identifier"))
        #expect(
            ArtifactDecodingError.duplicateKey(path: "<root>", key: "deadlines")
                .description.contains("deadlines")
        )
        #expect(
            ArtifactDecodingError.missingRequiredField(path: "schemaVersion")
                .description.contains("schemaVersion")
        )
    }

    private func assertEveryFieldRequired<Value: Codable & Equatable>(
        _ value: Value,
        _ type: Value.Type,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let complete = try CanonicalArtifactPayload.bytes(value)
        #expect(
            try decoder.decode(type, from: complete) == value,
            "\(type) should decode from its own encoding",
            sourceLocation: sourceLocation
        )
        let keys = try CanonicalArtifactPayload.topLevelKeys(value)
        #expect(!keys.isEmpty, "\(type) encodes no fields", sourceLocation: sourceLocation)
        for key in keys {
            let removed = try CanonicalArtifactPayload.removingTopLevelKey(key, from: value)
            let mutated = try #require(
                removed,
                "\(type).\(key) was not present",
                sourceLocation: sourceLocation
            )
            #expect(
                throws: ArtifactDecodingError.self,
                "\(type) decoded without \(key), so something supplied a default",
                sourceLocation: sourceLocation
            ) {
                try decoder.decode(type, from: mutated)
            }
        }
    }
}
