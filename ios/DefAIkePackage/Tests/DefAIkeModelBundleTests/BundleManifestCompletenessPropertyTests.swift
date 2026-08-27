import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Design Property 26: Model Bundle manifests are complete and mutation-sensitive.
//
// The design states it as: for any bounded artifact tree and candidate manifest,
// verification succeeds only when every required component version, self-test
// specification, fixture, expected result, artifact identity, size, canonical path, and
// digest appears exactly once and matches; adding, removing, renaming, duplicating, or
// changing any declared artifact or compatibility field causes rejection before
// activation.
//
// Two directions, and both are needed for the word "only" to mean anything. A file that
// asserted refusals alone would pass if the verifier refused everything, and a file that
// asserted acceptance alone would pass if it accepted everything. So each generated case
// builds one bounded artifact tree and quantifies four halves over it:
//
//   * **the completeness half** — the generated baseline really is complete in the sense
//     Requirement 10.5 describes, judged by a model written from the requirement text
//     rather than from the code under test, and the real verification path admits it as
//     far as the weight measurement. Every declared artifact appears exactly once, at a
//     canonical relative path, with a positive byte count, disjoint from every other
//     declared path, and the tree holds nothing the manifest does not account for
//     (Requirements 10.5, 10.8);
//   * **the digest half** — the tree digest every directory artifact's record carries is a
//     function of that tree and nothing else: enumeration order cannot change it, and no
//     one-member change leaves it alone (Requirement 10.5);
//   * **the mutation half** — over the generated tree, adding, removing, renaming,
//     duplicating, or changing exactly one artifact or field is refused by name, before
//     activation, with nothing becoming active. Twenty-seven mutations across seven
//     families, one change per candidate (Requirements 10.5, 10.7, 10.8, 10.9, 10.10);
//   * **the unrepresentable half** — two ways a declared artifact could appear twice are
//     refused before a candidate is even assembled: a repeated declared path is not a
//     manifest value at all, and a declared path nested inside another is refused while
//     the manifest is parsed (Requirement 10.5).
//
// ## Why the pass signal is a refusal, and what that costs
//
// Requirement 10.4 pins the weight-blob digest to one specific SHA-256 value, so passing
// the weight measurement requires the actual approved weight blob. That artifact is not in
// this repository, and fabricating a digest would disable the one check that pins model
// identity to bytes. So the complete unmutated candidate stops at
// `modelWeightDigestMismatch`, and that finding is this file's "everything before it
// passed" signal — the same signal `ArtifactTreeVerificationTests`,
// `ReleaseSelfTestVerificationTests`, and Property 2 use. Two observations keep it from
// being a vacuous stopping point:
//
//   * the weight blob is streamed exactly twice for an admitted candidate — once while
//     the integrity step hashes the declared model tree, once by the compatibility step's
//     own measurement — and **never twice** for a mutated one, so every refusal below
//     provably landed before the candidate was admitted; and
//   * the generated weight-blob content, the generated extra tree members, and the
//     generated fixture set vary per case, so the terminal is quantified over trees rather
//     than asserted about one fixture.
//
// Whether the real released blob hashes to the required value is an integration question
// against the real immutable artifact, and it belongs to task 6.11. Nothing here is
// release evidence: every policy, key, digest, fixture, expectation, path, and identifier
// below is **synthetic** and exists so a verifier that takes approved inputs can be called
// at all. No signature algorithm ran — the stand-in is `sha256(keyMaterial ‖ message)` —
// no compiled model was loaded, and no fixture parity was measured. No approved fixture
// suite, device validation plan, or offline trust store exists in this repository, and
// nothing below fabricates one.
//
// ## What this file does not assert
//
//   * That activation and rollback are atomic under injected failures, or that a failed
//     activation leaves a previously active bundle byte-for-byte unchanged. That is
//     Property 27's statement. The mutation half asserts only that nothing became active,
//     which is the part Property 26 needs in order to say "before activation".
//   * That the sole permitted checkpoint, weight digest, program kind, precision, and
//     deployment target are the ones the requirements name. That is Property 2's.
//   * That a session keeps its bound bundle snapshot. That is Property 13's.
//   * Known-answer signature or Core ML vectors, and anything about the real 43 MB weight
//     blob. Those belong to the integration tests of task 6.11.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: every
// throwing assembler, parser, verifier, and activator call is wrapped into a value or
// reported through `Issue.record`, and ``BundleCompletenessWitness`` counts the cases and
// every arm *outside* the body, where an issue is not suppressed. The arm counters are
// compared against the case count rather than against a floor, and the last thing the body
// does is record that it reached the end, so a case that stopped early is countable.

extension Tag {
    /// Design Property 26.
    ///
    /// Declared here rather than in a shared tag namespace: each design property gets one
    /// dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property26BundleManifestCompleteness: Self
}

@Suite(
    "Property 26: Model Bundle manifests are complete and mutation-sensitive",
    .tags(.property26BundleManifestCompleteness)
)
struct BundleManifestCompletenessPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is
    /// composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 10.5, 10.7, 10.8, 10.9, 10.10**
    @Test("Only a complete, unmutated manifest and artifact tree reaches the weight measurement")
    func onlyACompleteBundleIsAdmitted() async {
        let witness = BundleCompletenessWitness()

        await propertyCheck(input: ManifestTreeShape.generator) { shape in
            witness.record(shape)

            let scenario = BundleCompletenessScenario.assembled(shape, witness: witness)
            scenario.checkTheGeneratedBaselineIsComplete()
            scenario.checkTreeDigestsAreDeterministicAndSensitive()
            scenario.checkASecondDeclarationOfOneArtifactIsUnrepresentable()
            await scenario.checkEveryOneChangeMutationIsRefusedBeforeActivation()

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The reference model of "complete"

/// What Requirement 10.5 means by a manifest that carries identity and digest metadata for
/// every released artifact, written from the requirement rather than from the code under
/// test.
///
/// Small on purpose. Its value is that a generated baseline is confirmed complete, and every
/// tree mutation confirmed *incomplete*, by a second reading of the requirement. Without it
/// the mutation half would be measuring departures from whatever the implementation happens
/// to accept, and a refusal would not be attributable to the change the arm made.
private enum ReferenceBundleCompleteness {
    /// The first reason `tree` and `declared` are not a complete, matching pair, or `nil`
    /// when they are.
    ///
    /// Two halves, because Requirement 10.5 has two. The **identity** half is structural:
    /// every artifact declared exactly once, at a canonical relative path, of the kind its
    /// record claims, present in the tree, with the tree holding nothing the manifest does
    /// not account for. The **match** half is over bytes: every declared size and digest is
    /// the size and digest of the content actually there. A model with only the first half
    /// would call a candidate whose weight blob changed "complete", which is exactly the
    /// mistake this property exists to rule out.
    ///
    /// The directory-tree digest is computed with ``BundleTreeDigest``, the same primitive
    /// the verifier uses, under the construction the candidate's own approved
    /// canonicalization profile names. That is deliberate rather than a shortcut: this
    /// file's digest half independently pins that primitive's determinism and sensitivity
    /// over generated trees, so using it here does not assume what it is being used to
    /// check. Nothing else about the verifier is restated — in particular this returns a
    /// reason, never a ``ModelBundleVerificationError``, so no arm's expected finding comes
    /// from here.
    ///
    /// Returns the first defect rather than all of them: one cause is what a finding names,
    /// and stopping early keeps the model cheap for a tree at the entry ceiling.
    static func firstDefect(
        tree: FakeBundleTree,
        declared: [ArtifactDigestRecord],
        construction: BundleTreeDigestConstruction
    ) -> String? {
        let entries = tree.treeEntries

        // MARK: The identity half

        guard !declared.isEmpty else { return "the manifest declares no artifacts at all" }
        var seenDeclared = Set<String>()
        for record in declared {
            let path = record.path.rawValue
            if !seenDeclared.insert(path).inserted {
                return "declared \"\(path)\" more than once"
            }
            if CanonicalRelativePath(path) == nil {
                return "declared \"\(path)\" is not a canonical relative path"
            }
            if record.byteCount == 0 {
                return "declared \"\(path)\" accounts for no bytes"
            }
            if ReservedBundleFile.names.contains(path) {
                return "declared \"\(path)\" is a reserved root file"
            }
        }

        // Declared paths are pairwise disjoint: with one nested inside another the same
        // bytes would carry two digest records and "the digest of this path" is ambiguous.
        for outer in declared {
            for inner in declared where inner.path != outer.path {
                if inner.path.rawValue.hasPrefix(outer.path.rawValue + "/") {
                    return
                        "declared \"\(inner.path.rawValue)\" lies inside \"\(outer.path.rawValue)\""
                }
            }
        }

        // The tree reports each path once, holds only files and directories, holds only
        // canonical relative paths, and stays inside the walked ceiling.
        if entries.count > ModelBundleIntegrityVerifier.maximumTreeEntryCount {
            return "the tree holds \(entries.count) entries, above the walked ceiling"
        }
        var seenEntries = Set<String>()
        for entry in entries {
            if !seenEntries.insert(entry.rawPath).inserted {
                return "the tree reports \"\(entry.rawPath)\" more than once"
            }
            switch entry.kind {
            case .file, .directory:
                break
            case .symbolicLink:
                return "\"\(entry.rawPath)\" is a symbolic link"
            case .other:
                return "\"\(entry.rawPath)\" is neither a file nor a directory"
            }
            if CanonicalRelativePath(entry.rawPath) == nil {
                return "\"\(entry.rawPath)\" is not a canonical relative path"
            }
        }

        // Both reserved root files are present as regular files.
        for name in ReservedBundleFile.names.sorted() {
            guard let match = entries.first(where: { $0.rawPath == name }) else {
                return "the bundle root has no \(name)"
            }
            if case .file = match.kind {} else {
                return "\(name) is not a regular file"
            }
        }

        // Declared-only contents: every present entry is reserved, declared, an implied
        // container of a declared path, or a member of a declared directory tree.
        let declaredPaths = Set(declared.map(\.path.rawValue))
        let containers = declaredPaths.reduce(into: Set<String>()) {
            $0.formUnion(ModelBundleIntegrityVerifier.strictAncestors(of: $1))
        }
        let treeRoots = declared.filter { $0.kind == .directoryTree }.map { $0.path.rawValue + "/" }
        for entry in entries {
            let path = entry.rawPath
            if ReservedBundleFile.names.contains(path) { continue }
            if declaredPaths.contains(path) { continue }
            if containers.contains(path) { continue }
            if treeRoots.contains(where: { path.hasPrefix($0) }) { continue }
            return "\"\(path)\" is present but not accounted for by the manifest"
        }

        // MARK: The match half

        let byPath = entries.reduce(into: [String: BundleTreeEntry]()) { $0[$1.rawPath] = $1 }
        for record in declared {
            let path = record.path.rawValue
            guard let entry = byPath[path] else {
                return "declared \"\(path)\" is absent from the tree"
            }
            let isDirectory: Bool
            if case .directory = entry.kind { isDirectory = true } else { isDirectory = false }
            guard isDirectory == (record.kind == .directoryTree) else {
                return "declared \"\(path)\" is not a \(record.kind.rawValue)"
            }

            switch record.kind {
            case .file:
                let bytes = tree.fileBytes[path] ?? []
                if UInt64(bytes.count) != record.byteCount {
                    return """
                        declared \"\(path)\" holds \(bytes.count) bytes; its record says \
                        \(record.byteCount)
                        """
                }
                if StreamingSHA256.digest(of: bytes) != record.digest {
                    return "declared \"\(path)\" does not match its declared digest"
                }
            case .directoryTree:
                let prefix = path + "/"
                var members: [BundleTreeDigest.Member] = []
                var total: UInt64 = 0
                for member in entries where member.rawPath.hasPrefix(prefix) {
                    let relative = String(member.rawPath.dropFirst(prefix.count))
                    switch member.kind {
                    case .directory:
                        members.append(.directory(relativePath: relative))
                    case .file:
                        let bytes = tree.fileBytes[member.rawPath] ?? []
                        total += UInt64(bytes.count)
                        members.append(
                            .file(
                                relativePath: relative,
                                byteCount: UInt64(bytes.count),
                                digest: StreamingSHA256.digest(of: bytes)
                            )
                        )
                    case .symbolicLink, .other:
                        continue
                    }
                }
                if members.isEmpty {
                    return "declared directory tree \"\(path)\" contains nothing"
                }
                if total != record.byteCount {
                    return """
                        declared tree \"\(path)\" holds \(total) bytes; its record says \
                        \(record.byteCount)
                        """
                }
                if BundleTreeDigest.digest(of: members, construction: construction)
                    != record.digest
                {
                    return "declared tree \"\(path)\" does not match its declared digest"
                }
            }
        }

        return nil
    }
}

// MARK: - What one candidate changes

/// Which of the five change families the task names, plus the two groups Requirements 10.5
/// and 10.8 require beyond them.
private enum MutationFamily: String, Hashable, Sendable, CaseIterable {
    case add
    case remove
    case rename
    case duplicate
    case mutate
    /// Canonical paths, symbolic links, traversal, and entry kinds.
    case structure
    /// The bounded-size ceilings a candidate cannot exceed.
    case bound
}

/// One change applied to an otherwise complete candidate.
///
/// Payload-free so the set is enumerable and the witness can require that every one of
/// them was actually refused by the real path. Which member, path, byte, or component a
/// case changes comes from the generated shape rather than from a payload, so a family is
/// exercised across its members over 100 cases instead of collapsing onto one.
private enum BundleMutation: String, Hashable, Sendable, CaseIterable {
    // MARK: Add — an artifact the manifest does not account for appears

    case addUndeclaredFile = "add-undeclared-file"
    case addUndeclaredDirectory = "add-undeclared-directory"
    case addUndeclaredRootFile = "add-undeclared-root-file"
    case addEmptyDirectoryInsideDeclaredTree = "add-empty-directory-inside-declared-tree"
    case addEmptyFileInsideDeclaredTree = "add-empty-file-inside-declared-tree"

    // MARK: Remove — something the manifest or catalogue declares is gone

    case removeDeclaredFileArtifact = "remove-declared-file-artifact"
    case removeDeclaredTreeMemberFile = "remove-declared-tree-member-file"
    case removeDeclaredTreeMemberDirectory = "remove-declared-tree-member-directory"
    case removeCataloguedFixtureAsset = "remove-catalogued-fixture-asset"

    // MARK: Rename — the same bytes under a different path

    case renameDeclaredFileArtifact = "rename-declared-file-artifact"
    case renameDeclaredTreeMember = "rename-declared-tree-member"

    // MARK: Duplicate — one thing declared or reported twice

    case duplicateTreeEntry = "duplicate-tree-entry"
    case duplicateManifestKey = "duplicate-manifest-key"

    // MARK: Mutate — one artifact's bytes, or one declared field

    case mutateWeightBlobBytes = "mutate-weight-blob-bytes"
    case mutateDeclaredFileBytes = "mutate-declared-file-bytes"
    case growDeclaredFile = "grow-declared-file"
    case shrinkDeclaredFile = "shrink-declared-file"
    case mutateComponentVersion = "mutate-component-version"
    case mutateSelfTestSpecificationVersion = "mutate-self-test-specification-version"
    case mutateFixtureSuiteReference = "mutate-fixture-suite-reference"
    case mutateCataloguedFixtureDigest = "mutate-catalogued-fixture-digest"
    case mutateCataloguedFixtureByteCount = "mutate-catalogued-fixture-byte-count"

    // MARK: Structure — what a verified tree cannot contain at all

    case addSymbolicLink = "add-symbolic-link"
    case addNoncanonicalPath = "add-noncanonical-path"
    case addUnsupportedEntryKind = "add-unsupported-entry-kind"

    // MARK: Bounds

    case exceedTreeEntryBudget = "exceed-tree-entry-budget"
    case exceedManifestByteCeiling = "exceed-manifest-byte-ceiling"

    var family: MutationFamily {
        switch self {
        case .addUndeclaredFile, .addUndeclaredDirectory, .addUndeclaredRootFile,
            .addEmptyDirectoryInsideDeclaredTree, .addEmptyFileInsideDeclaredTree:
            .add
        case .removeDeclaredFileArtifact, .removeDeclaredTreeMemberFile,
            .removeDeclaredTreeMemberDirectory, .removeCataloguedFixtureAsset:
            .remove
        case .renameDeclaredFileArtifact, .renameDeclaredTreeMember:
            .rename
        case .duplicateTreeEntry, .duplicateManifestKey:
            .duplicate
        case .mutateWeightBlobBytes, .mutateDeclaredFileBytes, .growDeclaredFile,
            .shrinkDeclaredFile, .mutateComponentVersion,
            .mutateSelfTestSpecificationVersion, .mutateFixtureSuiteReference,
            .mutateCataloguedFixtureDigest, .mutateCataloguedFixtureByteCount:
            .mutate
        case .addSymbolicLink, .addNoncanonicalPath, .addUnsupportedEntryKind:
            .structure
        case .exceedTreeEntryBudget, .exceedManifestByteCeiling:
            .bound
        }
    }

    /// What this change claims about Requirement 10.5's completeness, measured against
    /// ``ReferenceBundleCompleteness`` per arm.
    ///
    /// Declared per mutation rather than derived from the measurement, so the two can
    /// disagree and the arm fails. The split is the substantive part: seven of the
    /// twenty-seven changes leave a bundle that is still complete and matching in every
    /// respect, and their refusals therefore prove something no tree check can — that the
    /// declared-field and approved-bound comparisons are independent of the tree comparison
    /// (Requirements 10.7 through 10.10).
    var completenessClaim: CompletenessClaim {
        switch self {
        // A component version, the self-test specification version, the fixture-suite
        // reference, a catalogued fixture's declared digest or size, a catalogued fixture
        // the tree consistently does not carry, and a tightened policy ceiling. Each leaves
        // a tree that holds exactly what its manifest declares, byte for byte.
        case .mutateComponentVersion, .mutateSelfTestSpecificationVersion,
            .mutateFixtureSuiteReference, .mutateCataloguedFixtureDigest,
            .mutateCataloguedFixtureByteCount, .removeCataloguedFixtureAsset,
            .exceedManifestByteCeiling:
            .staysCompleteAndMatching
        // The document declares one key twice, so "what the manifest declares" is not a
        // single answer and completeness is not a question that can be asked of it.
        case .duplicateManifestKey:
            .declaredSetIsNotDecodable
        default:
            .stopsBeingCompleteAndMatching
        }
    }
}

/// What one change claims about the completeness of the candidate it produced.
private enum CompletenessClaim: String, Hashable, Sendable, CaseIterable {
    /// The tree still holds exactly what the manifest declares, byte for byte, so the
    /// refusal must come from the declared field or the approved bound the arm changed.
    case staysCompleteAndMatching = "stays-complete-and-matching"

    /// The change is itself a departure from completeness.
    case stopsBeingCompleteAndMatching = "stops-being-complete-and-matching"

    /// The manifest document cannot be read as one manifest, so the declared set — and
    /// therefore completeness — is undefined. The refusal is a document-level one.
    case declaredSetIsNotDecodable = "declared-set-is-not-decodable"
}

/// How many times a candidate's weight blob is streamed during one attempt.
///
/// The observation that turns "refused" into "refused before the candidate was admitted".
/// An admitted candidate streams it twice — once while the integrity step hashes the
/// declared model tree, once by the compatibility step's own measurement — so a mutated
/// candidate that streams it twice reached the measurement, which is the one thing no
/// refusal may do.
private enum WeightBlobReads: Hashable, Sendable {
    /// Exactly this many, because the step that refused the candidate is fixed in the
    /// verification order relative to the model tree's hashing.
    case exactly(Int)

    /// Fewer than the admitted control's two, without naming the number.
    ///
    /// Used where the exact count depends on the position of the offending artifact in the
    /// declared-path order, which the production code owns and this file deliberately does
    /// not restate. The claim that matters — the refusal landed before the compatibility
    /// step's measurement — is the same either way.
    case fewerThanTheAdmittedControl
}

// MARK: - Generated shape

/// One generated bounded artifact tree and the choices its mutations draw on.
///
/// Every field is a bounded integer or a flag, and each value is read off the shape by
/// modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct ManifestTreeShape: Sendable, CustomStringConvertible {
    /// Drives the generated content, member names, and identifiers, so a case's values vary
    /// together and a failing case names one seed.
    let seed: Int

    let extraMemberIndex: Int
    let subdirectoryIndex: Int
    let fixtureCountIndex: Int
    let declaredFileIndex: Int
    let duplicatedEntryIndex: Int
    let duplicatedKeyIndex: Int
    let componentIndex: Int
    let noncanonicalIndex: Int
    let bytePositionIndex: Int

    /// Whether the mutation arms are attempted in reverse declaration order.
    ///
    /// Each arm gets its own activator over its own content store, so no arm can depend on
    /// another's outcome; exercising both orders is what makes that a measurement rather
    /// than a claim about the harness.
    let armOrderReversed: Bool

    // MARK: Identifiers

    /// A per-case token, kept positive so no generated identifier can collapse onto a
    /// placeholder or a zero-valued component.
    var token: String { "\(1 + seed % 999)" }

    var bundleID: ModelBundleID { Sample.bundle("bundle.p26-\(token)") }

    // MARK: The generated tree content

    /// Eleven bytes of synthetic weight-blob content.
    ///
    /// Exactly the length of the assembler's own placeholder, following the same choice
    /// Property 2's file records: the declared tree record is derived from the tree after
    /// this replacement, and matching the placeholder's length keeps this substitution from
    /// interacting with any size check. Nothing about the content matters beyond varying
    /// per case, and no synthetic content can hash to the digest Requirement 10.4 pins —
    /// that is the check working, not a gap.
    var weightBlobBytes: [UInt8] {
        var bytes = Array("w26-".utf8)
        bytes.append(contentsOf: Self.hexadecimal(seed, digits: 7))
        return bytes
    }

    var weightBlobToken: String { String(decoding: weightBlobBytes, as: UTF8.self) }

    /// How many extra files this case adds inside the declared compiled-model tree.
    ///
    /// Zero through two, so the generated tree is sometimes the assembler's minimum and
    /// sometimes larger, and every arm below has to hold for both.
    var extraModelMemberCount: Int { extraMemberIndex % 3 }

    /// Whether this case adds a nested subdirectory inside the declared model tree.
    var addsModelSubdirectory: Bool { subdirectoryIndex % 2 == 0 }

    var modelSubdirectory: String {
        "\(CompatibleBundleAssembler.modelTreePath)/p26-nested-\(token)"
    }

    func extraModelMemberPath(_ index: Int) -> String {
        "\(CompatibleBundleAssembler.modelTreePath)/p26-extra-\(index)-\(token).bin"
    }

    func extraModelMemberBytes(_ index: Int) -> [UInt8] {
        Array("p26-member-\(index)-".utf8) + Self.hexadecimal(seed &+ index, digits: 6)
    }

    /// Adds this case's generated content to an assembling tree.
    ///
    /// Runs inside the assembler's `treeOverrides` hook, before the declared records are
    /// derived, so the resulting manifest describes the generated tree exactly.
    func applyGeneratedContent(to tree: inout FakeBundleTree) {
        tree.overwriteContent(CompatibleBundleAssembler.weightBlobPath, bytes: weightBlobBytes)
        if addsModelSubdirectory {
            tree.addDirectory(modelSubdirectory)
        }
        for index in 0..<extraModelMemberCount {
            tree.addFile(extraModelMemberPath(index), bytes: extraModelMemberBytes(index))
        }
    }

    // MARK: The generated self-test evidence

    /// Two or three catalogued fixtures per case.
    ///
    /// Never one. Every self-test arm below makes exactly one fixture defective, and with a
    /// second sound fixture beside it the refusal cannot depend on which case the plan
    /// resolves first. Two is also the minimum for the removal arm: a bundle that declares
    /// a fixture tree and ships none of it has an artifact accounting for no bytes, which
    /// the manifest schema refuses before verification is reached.
    var fixtureCount: Int { 2 + fixtureCountIndex % 2 }

    func fixtureCaseIdentifier(_ index: Int) -> String { "self-test.p26-\(index)-\(token)" }
    func fixtureIdentifier(_ index: Int) -> String { "fixture.p26-\(index)-\(token)" }
    func fixtureAssetPath(_ index: Int) -> String { "p26-\(index)-\(token).bin" }

    func fixtureBytes(_ index: Int) -> [UInt8] {
        Array("p26-fixture-\(index)-".utf8)
            + Self.hexadecimal(seed &+ 31 &* index, digits: 5 + index % 3)
    }

    /// The declared expected results one generated case carries.
    ///
    /// Alternated across two kinds so "expected result" is exercised as more than one
    /// shape, and both are coherent: one kind per case, and never an Analysis Error beside
    /// a successful result.
    func fixtureExpectations(_ index: Int) -> [SelfTestExpectation] {
        index % 2 == 0
            ? [.pixelLabel(.noStrongSignalDetected)]
            : [.rawLogit(value: 1.5, tolerance: Sample.nonNegativeDecimal(0))]
    }

    /// This case's generated self-test set.
    func selfTests() -> [SampleSelfTest] {
        (0..<fixtureCount).map { index in
            SampleSelfTest(
                caseID: fixtureCaseIdentifier(index),
                fixtureID: fixtureIdentifier(index),
                suiteRelativePath: fixtureAssetPath(index),
                bytes: fixtureBytes(index),
                expectations: fixtureExpectations(index)
            )
        }
    }

    /// The fixture one self-test arm makes defective. Always the last, so the ones before
    /// it resolve and the refusal is attributable to the defect rather than to the set.
    var defectiveFixtureIndex: Int { fixtureCount - 1 }

    // MARK: Mutation choices

    /// The two separately declared *file* artifacts, in the order the assembler adds them.
    static let declaredFilePaths = [
        CompatibleBundleAssembler.selfTestsPath,
        CompatibleBundleAssembler.fixtureCatalogPath,
    ]

    /// Which declared file artifact the remove, rename, and byte arms operate on.
    var declaredFilePath: String {
        Self.declaredFilePaths[declaredFileIndex % Self.declaredFilePaths.count]
    }

    /// Existing file paths a duplicate-entry arm can report twice.
    ///
    /// Includes both reserved root files: a candidate that reported its manifest twice
    /// would make "the manifest of this bundle" ambiguous, and the enumeration check is
    /// what refuses it.
    var duplicatedEntryPath: String {
        let table = [
            CompatibleBundleAssembler.selfTestsPath,
            CompatibleBundleAssembler.fixtureCatalogPath,
            CompatibleBundleAssembler.weightBlobPath,
            ModelBundleManifest.manifestFileName,
        ]
        return table[duplicatedEntryIndex % table.count]
    }

    /// One top-level manifest member to declare twice, with a valid JSON value.
    ///
    /// Four members rather than one: a scan that only looked at the first key, or only at
    /// string-valued members, would accept three of these.
    var duplicatedManifestMember: (key: String, jsonValue: String) {
        let table = [
            ("bundleID", "\"bundle.p26-duplicate\""),
            ("signingKey", "\"key.p26-duplicate\""),
            ("schemaVersion", "1"),
            ("artifacts", "[]"),
        ]
        return table[duplicatedKeyIndex % table.count]
    }

    /// A canonical relative path that is not the noncanonical form under test.
    var addedFilePath: String { "artifacts/p26-added-\(token).bin" }
    var addedDirectoryPath: String { "artifacts/p26-added-dir-\(token)" }
    var addedRootFilePath: String { "p26-root-\(token).txt" }
    var addedTreeDirectoryPath: String {
        "\(CompatibleBundleAssembler.modelTreePath)/p26-added-dir-\(token)"
    }
    var addedTreeFilePath: String {
        "\(CompatibleBundleAssembler.modelTreePath)/p26-added-\(token).bin"
    }
    var symbolicLinkPath: String { "artifacts/p26-link-\(token)" }
    var unsupportedEntryPath: String { "artifacts/p26-socket-\(token)" }

    /// The path a renamed declared file artifact lands on.
    var renamedFilePath: String { "artifacts/p26-renamed-\(token).canonical.json" }

    /// The path a renamed model-tree member lands on.
    var renamedTreeMemberPath: String {
        "\(CompatibleBundleAssembler.modelTreePath)/p26-renamed-\(token).bin"
    }

    /// A path form ``CanonicalRelativePath`` refuses, and a stable name for that form.
    ///
    /// Traversal, absolute, empty component, current-directory component, backslash, and
    /// embedded space: six separate ways a path could reach outside a bundle or normalize
    /// away, and a check that only rejected `..` would accept five of them.
    ///
    /// The name is carried alongside the path because the path itself is token-suffixed and
    /// therefore differs per case; the witness has to count forms drawn, not strings seen.
    var noncanonicalEntry: (form: String, path: String) {
        let table = [
            ("traversal", "artifacts/../escape-\(token).bin"),
            ("absolute", "/absolute-\(token).bin"),
            ("empty-component", "artifacts//double-\(token).bin"),
            ("current-directory", "artifacts/./same-\(token).bin"),
            ("backslash", "artifacts\\windows-\(token).bin"),
            ("embedded-space", "artifacts/with space-\(token).bin"),
        ]
        return table[noncanonicalIndex % table.count]
    }

    var noncanonicalPath: String { noncanonicalEntry.path }

    /// Which of the four component versions with an approved build-side counterpart is
    /// changed, and the replacement it takes.
    ///
    /// The other two of Requirement 10.7's six are covered separately: the self-test
    /// specification version by its own arm, and the Core ML component version as the
    /// neutral control, because it is the one member compatibility deliberately does not
    /// compare against a build-side identifier.
    var comparedComponentMember: String {
        let table = [
            "preprocessingContract",
            "calibrationPolicy",
            "verdictCopyCompatibility",
            "evidenceScope",
        ]
        return table[componentIndex % table.count]
    }

    var componentReplacement: String { "component.p26-\(token)" }
    var selfTestSpecificationReplacement: String { "spec.p26-\(token)" }
    var fixtureSuiteReplacement: String { "suite.p26-\(token)" }

    /// The neutral replacement for the Core ML component version.
    var neutralComponentReplacement: String { "component.core-ml-model-p26-\(token)" }

    // MARK: Ordering

    var orderedMutations: [BundleMutation] {
        armOrderReversed ? BundleMutation.allCases.reversed() : BundleMutation.allCases
    }

    // MARK: Description

    var description: String {
        """
        seed \(seed), bundle \(bundleID.rawValue), weight blob "\(weightBlobToken)", \
        \(extraModelMemberCount) extra model member(s), subdirectory \
        \(addsModelSubdirectory), \(fixtureCount) fixtures, \
        declared file "\(declaredFilePath)", duplicated entry "\(duplicatedEntryPath)", \
        duplicated key "\(duplicatedManifestMember.key)", \
        component "\(comparedComponentMember)", noncanonical "\(noncanonicalPath)", \
        byte position index \(bytePositionIndex), reversed \(armOrderReversed)
        """
    }

    // MARK: Generator

    /// The library's `zip` composes at most ten generators, and this shape has eleven
    /// fields, so the last two are composed into one nested pair first. Nesting keeps every
    /// field independently generated and the shrinkers composed, which folding a field into
    /// `seed` would not.
    static var generator: Generator<ManifestTreeShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            index,
            index,
            index,
            index,
            index,
            index,
            index,
            index,
            zip(Gen.int(in: 0...9_999), Gen.bool).eraseToAny()
        )
        .map { raw in
            ManifestTreeShape(
                seed: raw.0,
                extraMemberIndex: raw.1,
                subdirectoryIndex: raw.2,
                fixtureCountIndex: raw.3,
                declaredFileIndex: raw.4,
                duplicatedEntryIndex: raw.5,
                duplicatedKeyIndex: raw.6,
                componentIndex: raw.7,
                noncanonicalIndex: raw.8,
                bytePositionIndex: raw.9.0,
                armOrderReversed: raw.9.1
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (2, 3, 4, 6), so each
    /// table entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...959).eraseToAny()
    }

    /// Lowercase hexadecimal digits derived from `value`, for generated content.
    private static func hexadecimal(_ value: Int, digits: Int) -> [UInt8] {
        let alphabet = Array("0123456789abcdef".utf8)
        var mixed = UInt64(bitPattern: Int64(value)) &* 2_654_435_761 &+ 1
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits)
        for _ in 0..<digits {
            bytes.append(alphabet[Int(mixed & 0xF)])
            mixed >>= 4
        }
        return bytes
    }
}

// MARK: - Scoped manifest splicing

/// Replaces the string value of one member inside one top-level object member of a signed
/// manifest, leaving every other byte untouched.
///
/// Text splicing rather than a `JSONSerialization` round trip. Re-serializing a manifest
/// perturbs its exact decimals, and a Model Bundle manifest carries one — the upstream
/// Lowq boundary value the Calibration Policy pins — so a refusal after a round trip could
/// come from the perturbed decimal instead of from the field the arm is about.
///
/// Scoped rather than global, because a member name can occur in more than one object: a
/// manifest declares `minimumOS` twice, once in the model format and once in the
/// compatibility matrix. A global substitution would change two fields at once and the
/// finding would no longer name one cause.
///
/// Every refusal returns `nil` rather than the unchanged text, so an arm cannot assert
/// against a manifest it did not actually mutate.
private enum ScopedManifestSplice {
    struct Spliced {
        let text: String
        let previousValue: String
    }

    /// `text` with `object.member` set to `replacement`.
    static func setting(
        _ member: String,
        inObject object: String,
        to replacement: String,
        of text: String
    ) -> Spliced? {
        // The replacement is written into a JSON string body verbatim, so a value needing
        // an escape is refused rather than silently producing a malformed document.
        guard !replacement.contains("\""), !replacement.contains("\\") else { return nil }
        guard let scope = soleObjectValueRange(of: object, in: text) else { return nil }

        let needle = "\"\(member)\":\""
        guard let found = text.range(of: needle, options: .literal, range: scope),
            text.range(
                of: needle,
                options: .literal,
                range: found.upperBound..<scope.upperBound
            ) == nil
        else { return nil }

        let valueStart = found.upperBound
        guard let valueEnd = closingQuote(in: text, from: valueStart, before: scope.upperBound)
        else { return nil }

        // The splice has to change the record. Without this an arm could assert a refusal
        // against a manifest that is byte-identical to the one it started from.
        let previous = String(text[valueStart..<valueEnd])
        guard previous != replacement else { return nil }

        var mutated = text
        mutated.replaceSubrange(valueStart..<valueEnd, with: replacement)
        return Spliced(text: mutated, previousValue: previous)
    }

    /// The body of the sole top-level `"member":{...}` object, brace to matching brace.
    ///
    /// Depth tracking with string skipping is what makes this different from a substring
    /// search: a nested object can repeat a member name, and a string value can contain a
    /// brace.
    private static func soleObjectValueRange(
        of member: String,
        in text: String
    ) -> Range<String.Index>? {
        let needle = "\"\(member)\":{"
        guard let opening = text.range(of: needle, options: .literal),
            text.range(
                of: needle,
                options: .literal,
                range: opening.upperBound..<text.endIndex
            ) == nil
        else { return nil }

        var index = opening.upperBound
        var depth = 1
        while index < text.endIndex {
            switch text[index] {
            case "\"":
                guard let end = closingQuote(
                    in: text,
                    from: text.index(after: index),
                    before: text.endIndex
                ) else { return nil }
                index = text.index(after: end)
                continue
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return opening.upperBound..<index }
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The index of the quote that closes the string body starting at `start`.
    private static func closingQuote(
        in text: String,
        from start: String.Index,
        before limit: String.Index
    ) -> String.Index? {
        var index = start
        while index < limit {
            switch text[index] {
            case "\\":
                index = text.index(after: index)
                guard index < limit else { return nil }
            case "\"":
                return index
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// Prepends a duplicate top-level member to a manifest document.
///
/// A separate helper because this is not a value substitution: the resulting document is
/// still well-formed JSON, and the only thing wrong with it is that its outermost object
/// declares one key twice. `JSONDecoder` would silently keep one of the two, so the same
/// signed bytes could read as two different manifests, which is why Requirement 10.5's
/// "exactly once" has to be enforced before decoding.
private enum DuplicateManifestKeyEdit {
    /// `text` with `"key":jsonValue,` inserted immediately after the opening brace.
    ///
    /// Returns `nil` when `text` is not an object or already declares `key` more than once,
    /// so the arm cannot assert against a document whose duplication it did not create.
    static func prepending(
        key: String,
        jsonValue: String,
        to text: String
    ) -> String? {
        guard text.hasPrefix("{") else { return nil }
        let needle = "\"\(key)\":"
        guard let first = text.range(of: needle, options: .literal),
            text.range(
                of: needle,
                options: .literal,
                range: first.upperBound..<text.endIndex
            ) == nil
        else { return nil }
        return "{\"\(key)\":\(jsonValue)," + text.dropFirst()
    }
}

// MARK: - One mutated candidate

/// One change, the tree and approved inputs it is judged by, and the finding verification
/// must produce for it.
private struct MutationArm {
    let mutation: BundleMutation

    /// The candidate whose approved configuration, evidence scope, layout, verification
    /// policy, signature stand-in, and running context judge this arm.
    let assembled: CompatibleCandidate

    /// The tree the verifier reads. For most arms a mutated copy of the baseline's.
    let tree: FakeBundleTree

    let expectedFinding: ModelBundleVerificationError
    let weightBlobReads: WeightBlobReads

    /// Evidence that the change actually landed. Asserted per arm, so a no-op edit cannot
    /// pass as a refusal.
    let changedTheCandidate: Bool

    /// The first reason this arm's tree and its own manifest are not a complete, matching
    /// pair, or `nil` when they are. Compared against the mutation's declared claim.
    let measuredDefect: String?
}

// MARK: - One generated scenario

/// One generated bounded artifact tree, the approved inputs one build binds, and the real
/// verifiers and activator over it.
///
/// Every verifier, parser, and activator below is the production one. The approved
/// configuration, evidence scope, layout, verification policy, signature stand-in, and
/// running context all come from the assembled candidate, so the whole case is judged by
/// one build's approved inputs rather than by each arm's own.
private struct BundleCompletenessScenario {
    let shape: ManifestTreeShape
    let witness: BundleCompletenessWitness

    /// Present only when every fixture this case describes was buildable.
    private let built: Built?

    private struct Built {
        let baseline: CompatibleCandidate
        let controls: [MutationArm]
        let mutations: [MutationArm]
        let admittedWeightBlobReads: Int
    }

    // MARK: - Assembly

    static func assembled(
        _ shape: ManifestTreeShape,
        witness: BundleCompletenessWitness
    ) -> BundleCompletenessScenario {
        BundleCompletenessScenario(
            shape: shape,
            witness: witness,
            built: Self.build(shape, witness: witness)
        )
    }

    private static func build(
        _ shape: ManifestTreeShape,
        witness: BundleCompletenessWitness
    ) -> Built? {
        let selfTests = shape.selfTests()
        guard let baseline = try? CompatibleBundleAssembler.standard(
            bundleID: shape.bundleID,
            selfTests: selfTests,
            treeOverrides: { shape.applyGeneratedContent(to: &$0) }
        ) else {
            report("the generated baseline candidate must be assemblable", witness)
            return nil
        }

        // The two controls: the unmutated candidate, and one whose manifest was rewritten
        // and re-signed in a member no check compares. Without the second, every refusal
        // below could be an artifact of rewriting and re-signing a manifest rather than of
        // the field the arm changed.
        guard let neutral = neutralControlArm(shape, baseline: baseline, witness: witness) else {
            return nil
        }
        let controls = [controlArm(baseline: baseline), neutral]

        guard let mutations = mutationArms(shape, baseline: baseline, witness: witness) else {
            return nil
        }

        return Built(
            baseline: baseline,
            controls: controls,
            mutations: mutations,
            admittedWeightBlobReads: 2
        )
    }

    /// The unmutated candidate, which must reach the weight measurement on every case.
    ///
    /// Carries a mutation tag it does not use: the controls are run through the same arm
    /// machinery as the mutations so their terminal is measured by the same code, and the tag
    /// is never read for a control.
    private static func controlArm(baseline: CompatibleCandidate) -> MutationArm {
        MutationArm(
            mutation: .addUndeclaredFile,
            assembled: baseline,
            tree: baseline.integrity.tree,
            expectedFinding: .modelWeightDigestMismatch(baseline.layout.modelWeightBlob),
            weightBlobReads: .exactly(2),
            changedTheCandidate: false,
            measuredDefect: firstDefect(baseline, tree: baseline.integrity.tree)
        )
    }

    /// A candidate whose manifest was rewritten and re-signed in the one component version
    /// compatibility deliberately does not compare against a build-side identifier.
    ///
    /// It must reach the same terminal as the unmutated control. A lower number means
    /// splicing and re-signing is itself refusing candidates, and every refusal below would
    /// be measuring that instead of its own change.
    private static func neutralControlArm(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> MutationArm? {
        guard let spliced = spliced(
            baseline,
            member: "coreMLModel",
            inObject: "componentVersions",
            to: shape.neutralComponentReplacement
        ) else {
            report("the neutral component version must be spliceable", witness)
            return nil
        }
        return MutationArm(
            mutation: .addUndeclaredFile,
            assembled: spliced,
            tree: spliced.integrity.tree,
            expectedFinding: .modelWeightDigestMismatch(spliced.layout.modelWeightBlob),
            weightBlobReads: .exactly(2),
            changedTheCandidate:
                spliced.integrity.manifestBytes != baseline.integrity.manifestBytes,
            measuredDefect: firstDefect(spliced, tree: spliced.integrity.tree)
        )
    }

    // MARK: - The mutation arms

    private static func mutationArms(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> [MutationArm]? {
        let manifest = baseline.integrity.manifest
        let modelTree = Sample.path(CompatibleBundleAssembler.modelTreePath)
        let declaredFile = Sample.path(shape.declaredFilePath)

        guard let modelTreeRecord = manifest.artifacts.first(where: { $0.path == modelTree }),
            let declaredFileRecord = manifest.artifacts.first(where: { $0.path == declaredFile }),
            let declaredFileBytes = baseline.integrity.tree.fileBytes[shape.declaredFilePath],
            declaredFileBytes.count > 1
        else {
            report("the generated baseline must declare a model tree and two files", witness)
            return nil
        }

        // The model-tree member the remove and rename arms operate on. Deliberately not the
        // weight blob: removing that would be refused by the tree's byte count first, and
        // the arm would no longer be about the member it named.
        let memberPath = "\(CompatibleBundleAssembler.modelTreePath)/coremldata.bin"
        guard let memberBytes = baseline.integrity.tree.fileBytes[memberPath] else {
            report("the generated model tree must hold its compiled-model data file", witness)
            return nil
        }
        let weightDirectory = "\(CompatibleBundleAssembler.modelTreePath)/weights"

        var arms: [MutationArm] = []

        func treeArm(
            _ mutation: BundleMutation,
            _ finding: ModelBundleVerificationError,
            _ reads: WeightBlobReads,
            edit: (inout FakeBundleTree) -> Void
        ) {
            var tree = baseline.integrity.tree
            edit(&tree)
            arms.append(
                MutationArm(
                    mutation: mutation,
                    assembled: baseline,
                    tree: tree,
                    expectedFinding: finding,
                    weightBlobReads: reads,
                    changedTheCandidate: Self.differs(baseline.integrity.tree, tree),
                    measuredDefect: Self.firstDefect(baseline, tree: tree)
                )
            )
        }

        // MARK: Add

        treeArm(
            .addUndeclaredFile,
            .undeclaredTreeEntry(Sample.path(shape.addedFilePath)),
            .exactly(0)
        ) { $0.addFile(shape.addedFilePath, text: "p26 synthetic staging residue") }

        treeArm(
            .addUndeclaredDirectory,
            .undeclaredTreeEntry(Sample.path(shape.addedDirectoryPath)),
            .exactly(0)
        ) { $0.addDirectory(shape.addedDirectoryPath) }

        treeArm(
            .addUndeclaredRootFile,
            .undeclaredTreeEntry(Sample.path(shape.addedRootFilePath)),
            .exactly(0)
        ) { $0.addFile(shape.addedRootFilePath, text: "p26 synthetic notes") }

        // Inside a declared directory tree an addition is not "undeclared content", it is a
        // tree that no longer digests to its record. An empty directory and a zero-byte file
        // are used on purpose: both leave the tree's declared byte total alone, so the digest
        // is the sole cause and the finding names one thing.
        treeArm(
            .addEmptyDirectoryInsideDeclaredTree,
            .artifactDigestMismatch(modelTree),
            .exactly(1)
        ) { $0.addDirectory(shape.addedTreeDirectoryPath) }

        treeArm(
            .addEmptyFileInsideDeclaredTree,
            .artifactDigestMismatch(modelTree),
            .exactly(1)
        ) { $0.addFile(shape.addedTreeFilePath, bytes: []) }

        // MARK: Remove

        treeArm(
            .removeDeclaredFileArtifact,
            .declaredArtifactMissing(declaredFile),
            .exactly(0)
        ) { $0.removeEntry(shape.declaredFilePath) }

        treeArm(
            .removeDeclaredTreeMemberFile,
            .artifactByteCountMismatch(
                path: modelTree,
                declared: modelTreeRecord.byteCount,
                found: modelTreeRecord.byteCount - UInt64(memberBytes.count)
            ),
            .exactly(1)
        ) { $0.removeEntry(memberPath) }

        // Removing the directory entry while its member file stays leaves the byte total
        // alone and drops one record from the tree digest.
        treeArm(
            .removeDeclaredTreeMemberDirectory,
            .artifactDigestMismatch(modelTree),
            .exactly(1)
        ) { $0.removeEntry(weightDirectory) }

        // MARK: Rename

        // The presence pass runs before the declared-only pass, so the finding names the
        // path that went missing rather than the one that appeared. Both are true; the
        // missing declared artifact is the one an audit acts on.
        treeArm(
            .renameDeclaredFileArtifact,
            .declaredArtifactMissing(declaredFile),
            .exactly(0)
        ) { tree in
            tree.removeEntry(shape.declaredFilePath)
            tree.addFile(shape.renamedFilePath, bytes: declaredFileBytes)
        }

        treeArm(
            .renameDeclaredTreeMember,
            .artifactDigestMismatch(modelTree),
            .exactly(1)
        ) { tree in
            tree.removeEntry(memberPath)
            tree.addFile(shape.renamedTreeMemberPath, bytes: memberBytes)
        }

        // MARK: Duplicate

        treeArm(
            .duplicateTreeEntry,
            .duplicateTreeEntry(shape.duplicatedEntryPath),
            .exactly(0)
        ) { tree in
            let bytes = tree.fileBytes[shape.duplicatedEntryPath] ?? []
            tree.addEntry(
                BundleTreeEntry(
                    rawPath: shape.duplicatedEntryPath,
                    kind: .file(byteCount: UInt64(bytes.count))
                )
            )
        }

        // MARK: Structure

        treeArm(
            .addSymbolicLink,
            .symbolicLinkPresent(shape.symbolicLinkPath),
            .exactly(0)
        ) { $0.addEntry(BundleTreeEntry(rawPath: shape.symbolicLinkPath, kind: .symbolicLink)) }

        treeArm(
            .addNoncanonicalPath,
            .noncanonicalEntryPath(shape.noncanonicalPath),
            .exactly(0)
        ) {
            $0.addEntry(
                BundleTreeEntry(rawPath: shape.noncanonicalPath, kind: .file(byteCount: 1))
            )
        }

        treeArm(
            .addUnsupportedEntryKind,
            .unsupportedEntryKind(shape.unsupportedEntryPath),
            .exactly(0)
        ) { $0.addEntry(BundleTreeEntry(rawPath: shape.unsupportedEntryPath, kind: .other)) }

        // MARK: Byte mutations

        treeArm(
            .mutateWeightBlobBytes,
            .artifactDigestMismatch(modelTree),
            .exactly(1)
        ) { tree in
            var bytes = shape.weightBlobBytes
            let position = shape.bytePositionIndex % bytes.count
            bytes[position] ^= 0x01
            tree.overwriteContent(CompatibleBundleAssembler.weightBlobPath, bytes: bytes)
        }

        // One byte, same length, so the size still matches and the digest is the only thing
        // that changed. Which declared file is generated, and the exact number of weight-blob
        // reads depends on that file's position in the declared-path order — which the
        // production code owns — so the assertion is the order-independent one.
        treeArm(
            .mutateDeclaredFileBytes,
            .artifactDigestMismatch(declaredFile),
            .fewerThanTheAdmittedControl
        ) { tree in
            var bytes = declaredFileBytes
            let position = shape.bytePositionIndex % bytes.count
            bytes[position] ^= 0x01
            tree.overwriteContent(shape.declaredFilePath, bytes: bytes)
        }

        treeArm(
            .growDeclaredFile,
            .artifactReadExceededDeclaredBound(
                path: declaredFile,
                bound: declaredFileRecord.byteCount
            ),
            .fewerThanTheAdmittedControl
        ) { tree in
            tree.overwriteContent(
                shape.declaredFilePath,
                bytes: declaredFileBytes + Array("p26-appended".utf8)
            )
        }

        let shortened = declaredFileBytes.count / 2
        treeArm(
            .shrinkDeclaredFile,
            .artifactByteCountMismatch(
                path: declaredFile,
                declared: declaredFileRecord.byteCount,
                found: UInt64(shortened)
            ),
            .fewerThanTheAdmittedControl
        ) { tree in
            tree.overwriteContent(
                shape.declaredFilePath,
                bytes: Array(declaredFileBytes.prefix(shortened))
            )
        }

        // MARK: Bounded tree size

        let ceiling = ModelBundleIntegrityVerifier.maximumTreeEntryCount
        let existing = baseline.integrity.tree.treeEntries.count
        guard existing <= ceiling else {
            report("the generated baseline must fit inside the walked entry ceiling", witness)
            return nil
        }
        treeArm(
            .exceedTreeEntryBudget,
            .treeEntryBudgetExceeded(maximumEntryCount: ceiling, found: ceiling + 1),
            .exactly(0)
        ) { tree in
            for filler in 0..<(ceiling + 1 - existing) {
                tree.addEntry(
                    BundleTreeEntry(
                        rawPath: "artifacts/p26-filler-\(filler).bin",
                        kind: .file(byteCount: 0)
                    )
                )
            }
        }

        // MARK: Manifest text edits

        guard let duplicated = duplicateKeyArm(shape, baseline: baseline, witness: witness),
            let componentArm = componentVersionArm(shape, baseline: baseline, witness: witness),
            let specificationArm = specificationVersionArm(
                shape,
                baseline: baseline,
                witness: witness
            )
        else {
            return nil
        }
        arms.append(contentsOf: [duplicated, componentArm, specificationArm])

        // MARK: Reassembled variants

        guard let selfTestVariants = selfTestEvidenceArms(shape, baseline: baseline, witness: witness),
            let ceilingArm = manifestCeilingArm(shape, baseline: baseline, witness: witness)
        else {
            return nil
        }
        arms.append(contentsOf: selfTestVariants)
        arms.append(ceilingArm)

        guard Set(arms.map(\.mutation)) == Set(BundleMutation.allCases) else {
            let missing = Set(BundleMutation.allCases).subtracting(Set(arms.map(\.mutation)))
            report(
                "every declared mutation must be built; missing \(missing.map(\.rawValue).sorted())",
                witness
            )
            return nil
        }
        return arms
    }

    /// A manifest whose outermost object declares one key twice, re-signed over the
    /// rewritten bytes so the finding is the duplication rather than a broken signature.
    private static func duplicateKeyArm(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> MutationArm? {
        let member = shape.duplicatedManifestMember
        let text = String(decoding: baseline.integrity.manifestBytes, as: UTF8.self)
        guard let edited = DuplicateManifestKeyEdit.prepending(
            key: member.key,
            jsonValue: member.jsonValue,
            to: text
        ) else {
            report("the duplicated manifest member must be uniquely locatable", witness)
            return nil
        }
        var candidate = baseline
        candidate.integrity.replaceManifest(bytes: Array(edited.utf8))
        return MutationArm(
            mutation: .duplicateManifestKey,
            assembled: candidate,
            tree: candidate.integrity.tree,
            expectedFinding: .manifestDuplicateKey(member.key),
            weightBlobReads: .exactly(0),
            changedTheCandidate:
                candidate.integrity.manifestBytes != baseline.integrity.manifestBytes,
            // Not assessed: the document declares one key twice, so there is no single
            // declared set to compare the tree against. The arm's claim says so, and the
            // refusal it asserts is the document-level one.
            measuredDefect: nil
        )
    }

    /// One of the four component versions with an approved build-side counterpart, changed
    /// to a version this build does not bind (Requirements 10.7 and 10.8).
    private static func componentVersionArm(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> MutationArm? {
        guard let candidate = spliced(
            baseline,
            member: shape.comparedComponentMember,
            inObject: "componentVersions",
            to: shape.componentReplacement
        ) else {
            report("\(shape.comparedComponentMember) must be spliceable", witness)
            return nil
        }

        // Every expected value is read from the approved configuration this build binds,
        // never spelled here: a restated identifier would make the arm assert that the test
        // and the configuration agree rather than that the bundle and the build do.
        let expected: ArtifactID
        let component: BundleComponent
        switch shape.comparedComponentMember {
        case "preprocessingContract":
            expected = baseline.configuration.preprocessingContract.id
            component = .preprocessingContract
        case "calibrationPolicy":
            expected = baseline.configuration.calibrationPolicy.id
            component = .calibrationPolicy
        case "verdictCopyCompatibility":
            expected = baseline.configuration.verdictCopyCatalog.compatibilityID
            component = .verdictCopyCompatibility
        case "evidenceScope":
            expected = baseline.evidenceScope.id
            component = .evidenceScope
        default:
            report("\(shape.comparedComponentMember) is not a compared component", witness)
            return nil
        }
        guard let found = ArtifactID(shape.componentReplacement) else {
            report("the generated component replacement must be a canonical identifier", witness)
            return nil
        }
        return MutationArm(
            mutation: .mutateComponentVersion,
            assembled: candidate,
            tree: candidate.integrity.tree,
            expectedFinding: .componentVersionIncompatible(
                component: component,
                expected: expected,
                found: found
            ),
            weightBlobReads: .exactly(1),
            changedTheCandidate:
                candidate.integrity.manifestBytes != baseline.integrity.manifestBytes,
            measuredDefect: firstDefect(candidate, tree: candidate.integrity.tree)
        )
    }

    /// The manifest's self-test specification component version changed away from the
    /// version the declared specification artifact identifies itself as (Requirement 10.9).
    private static func specificationVersionArm(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> MutationArm? {
        guard let candidate = spliced(
            baseline,
            member: "selfTestSpecification",
            inObject: "componentVersions",
            to: shape.selfTestSpecificationReplacement
        ) else {
            report("the self-test specification version must be spliceable", witness)
            return nil
        }
        guard let componentVersion = ArtifactID(shape.selfTestSpecificationReplacement) else {
            report("the generated specification version must be canonical", witness)
            return nil
        }
        return MutationArm(
            mutation: .mutateSelfTestSpecificationVersion,
            assembled: candidate,
            tree: candidate.integrity.tree,
            expectedFinding: .selfTestSpecificationIdentifierMismatch(
                declared: baseline.specification.id,
                componentVersion: componentVersion
            ),
            weightBlobReads: .exactly(1),
            changedTheCandidate:
                candidate.integrity.manifestBytes != baseline.integrity.manifestBytes,
            measuredDefect: firstDefect(candidate, tree: candidate.integrity.tree)
        )
    }

    /// The three self-test evidence arms that need a consistently reassembled bundle.
    ///
    /// Each changes something inside a *declared artifact* — the specification's fixture
    /// suite reference, or one catalogue entry's declared digest or size — so the bundle has
    /// to be rebuilt around the change. Editing the artifact in place would break its
    /// declared digest and the finding would name integrity rather than the self-test
    /// evidence (Requirements 10.9 and 10.10).
    private static func selfTestEvidenceArms(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> [MutationArm]? {
        let defective = shape.defectiveFixtureIndex
        let selfTests = shape.selfTests()
        guard defective < selfTests.count else {
            report("the generated fixture set must have a last member", witness)
            return nil
        }

        // A specification naming a fixture suite the bundle does not carry.
        guard let suiteVariant = try? CompatibleBundleAssembler.standard(
            bundleID: shape.bundleID,
            selfTests: selfTests,
            specificationFixtureSuite: shape.fixtureSuiteReplacement,
            treeOverrides: { shape.applyGeneratedContent(to: &$0) }
        ),
            let suiteReference = ArtifactID(shape.fixtureSuiteReplacement)
        else {
            report("the fixture-suite variant must be assemblable", witness)
            return nil
        }

        // One catalogued fixture whose declared digest is not the digest of its bytes, so it
        // is not the fixture the expected results were approved against. Every other fixture
        // in the same catalogue is sound, so the refusal cannot depend on resolution order.
        var digestTests = selfTests
        let mismatchedDigest = StreamingSHA256.digest(
            of: shape.fixtureBytes(defective) + Array("p26-not-these-bytes".utf8)
        )
        digestTests[defective].declaredDigest = mismatchedDigest
        guard let digestVariant = try? CompatibleBundleAssembler.standard(
            bundleID: shape.bundleID,
            selfTests: digestTests,
            treeOverrides: { shape.applyGeneratedContent(to: &$0) }
        ) else {
            report("the fixture-digest variant must be assemblable", witness)
            return nil
        }

        // One catalogue entry that overstates its asset's size. Overstated rather than
        // understated so the measured count is known: an understated entry stops the read at
        // the declared bound and the real size is never measured.
        var sizeTests = selfTests
        let realCount = UInt64(shape.fixtureBytes(defective).count)
        sizeTests[defective].declaredByteCount = realCount + 16
        guard let sizeVariant = try? CompatibleBundleAssembler.standard(
            bundleID: shape.bundleID,
            selfTests: sizeTests,
            treeOverrides: { shape.applyGeneratedContent(to: &$0) }
        ) else {
            report("the fixture-size variant must be assemblable", witness)
            return nil
        }

        // One catalogued fixture asset removed while the specification still requires it.
        // Removed inside the assembler's hook, so the declared fixture-tree record is derived
        // without it and the bundle is internally consistent: the only defect is the fixture
        // the specification names and the tree does not hold (Requirement 10.10).
        let removedAssetPath =
            "\(CompatibleBundleAssembler.fixtureRootPath)/\(shape.fixtureAssetPath(defective))"
        guard let missingVariant = try? CompatibleBundleAssembler.standard(
            bundleID: shape.bundleID,
            selfTests: selfTests,
            treeOverrides: { tree in
                shape.applyGeneratedContent(to: &tree)
                tree.removeEntry(removedAssetPath)
            }
        ) else {
            report("the missing-fixture variant must be assemblable", witness)
            return nil
        }

        let defectiveFixture = Sample.fixtureID(shape.fixtureIdentifier(defective))
        return [
            MutationArm(
                mutation: .mutateFixtureSuiteReference,
                assembled: suiteVariant,
                tree: suiteVariant.integrity.tree,
                expectedFinding: .selfTestFixtureCatalogMismatch(
                    specification: suiteReference,
                    catalog: suiteVariant.catalog.id
                ),
                weightBlobReads: .exactly(1),
                changedTheCandidate: suiteVariant.specification.fixtureSuite != baseline
                    .specification.fixtureSuite,
                measuredDefect: firstDefect(suiteVariant, tree: suiteVariant.integrity.tree)
            ),
            MutationArm(
                mutation: .mutateCataloguedFixtureDigest,
                assembled: digestVariant,
                tree: digestVariant.integrity.tree,
                expectedFinding: .selfTestFixtureDigestMismatch(defectiveFixture),
                weightBlobReads: .exactly(1),
                changedTheCandidate: digestVariant.catalog != baseline.catalog,
                measuredDefect: firstDefect(digestVariant, tree: digestVariant.integrity.tree)
            ),
            MutationArm(
                mutation: .mutateCataloguedFixtureByteCount,
                assembled: sizeVariant,
                tree: sizeVariant.integrity.tree,
                expectedFinding: .selfTestFixtureByteCountMismatch(
                    fixture: defectiveFixture,
                    declared: realCount + 16,
                    found: realCount
                ),
                weightBlobReads: .exactly(1),
                changedTheCandidate: sizeVariant.catalog != baseline.catalog,
                measuredDefect: firstDefect(sizeVariant, tree: sizeVariant.integrity.tree)
            ),
            MutationArm(
                mutation: .removeCataloguedFixtureAsset,
                assembled: missingVariant,
                tree: missingVariant.integrity.tree,
                expectedFinding: .selfTestFixtureAssetMissing(
                    fixture: defectiveFixture,
                    path: Sample.path(removedAssetPath)
                ),
                weightBlobReads: .exactly(1),
                changedTheCandidate: missingVariant.integrity.tree.fileBytes[removedAssetPath]
                    == nil,
                measuredDefect: firstDefect(missingVariant, tree: missingVariant.integrity.tree)
            ),
        ]
    }

    /// The same manifest bytes under a policy whose ceiling does not admit them.
    ///
    /// The bound on a manifest is the active Bundle Verification Policy's number, not a
    /// constant in the verifier, so this arm changes the approved ceiling and leaves the
    /// bundle alone. The bytes are asserted identical to the baseline's, which is what makes
    /// `found` a measurement rather than a prediction.
    private static func manifestCeilingArm(
        _ shape: ManifestTreeShape,
        baseline: CompatibleCandidate,
        witness: BundleCompletenessWitness
    ) -> MutationArm? {
        let count = UInt64(baseline.integrity.manifestBytes.count)
        guard count > 1 else {
            report("the generated manifest must hold more than one byte", witness)
            return nil
        }
        let ceiling = count - 1
        guard let variant = try? CompatibleBundleAssembler.standard(
            bundleID: shape.bundleID,
            selfTests: shape.selfTests(),
            manifestByteCeiling: ceiling,
            treeOverrides: { shape.applyGeneratedContent(to: &$0) }
        ) else {
            report("the tightened-ceiling variant must be assemblable", witness)
            return nil
        }
        guard variant.integrity.manifestBytes == baseline.integrity.manifestBytes else {
            report("tightening the policy ceiling must not change the manifest bytes", witness)
            return nil
        }
        return MutationArm(
            mutation: .exceedManifestByteCeiling,
            assembled: variant,
            tree: variant.integrity.tree,
            expectedFinding: .manifestTooLarge(ceiling: ceiling, found: count),
            weightBlobReads: .exactly(0),
            changedTheCandidate: variant.integrity.policy.maximumManifestByteCount.value
                != baseline.integrity.policy.maximumManifestByteCount.value,
            measuredDefect: firstDefect(variant, tree: variant.integrity.tree)
        )
    }

    // MARK: - The completeness half

    /// The generated baseline is complete in Requirement 10.5's sense, and the real
    /// verification path admits it as far as the weight measurement.
    ///
    /// Runs first because every refusal below is measured against this: a baseline that was
    /// not complete would make every mutation arm a comparison between two defective
    /// candidates (Requirements 10.5, 10.8).
    func checkTheGeneratedBaselineIsComplete() {
        guard let built else { return }
        let manifest = built.baseline.integrity.manifest
        let entries = built.baseline.integrity.tree.treeEntries

        #expect(
            entries.count > ReservedBundleFile.names.count,
            "the generated baseline must hold more than its two reserved root files"
        )
        let defect = Self.firstDefect(built.baseline, tree: built.baseline.integrity.tree)
        #expect(
            defect == nil,
            "the generated baseline is not a complete, matching bundle: \(defect ?? "")"
        )

        // Exactly once, and nothing else. Asserted on the *verified* value rather than on
        // the manifest, because the verified inventory is what an activation receipt records
        // and what a session binds.
        guard let verified = Self.verifiedTree(built.baseline) else {
            report("the generated baseline must pass integrity verification")
            return
        }
        let verifiedPaths = verified.verifiedArtifacts.map(\.path.rawValue)
        #expect(
            Set(verifiedPaths) == manifest.declaredPaths,
            "the verified inventory is not the declared set"
        )
        #expect(
            verifiedPaths.count == Set(verifiedPaths).count,
            "the verified inventory repeats a path: \(verifiedPaths)"
        )
        #expect(
            verifiedPaths == verifiedPaths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
            "the verified inventory is not ordered by the bytes of its paths"
        )
        #expect(
            verified.manifestDigest
                == StreamingSHA256.digest(of: built.baseline.integrity.manifestBytes),
            "the verified manifest digest is not the digest of the bytes that were read"
        )
        // Every role the approved layout names resolves to a declared artifact of the kind
        // that role requires. This is the part of "complete" a path set alone cannot state.
        for role in ApprovedBundleLayout.separatelyDeclaredRoles {
            let path = built.baseline.layout.path(for: role)
            let record = verified.verifiedArtifact(at: path)
            #expect(record != nil, "the \(role) at \"\(path.rawValue)\" is not declared")
            #expect(
                record?.kind == role.requiredKind,
                "the \(role) is not a \(role.requiredKind.rawValue)"
            )
        }

        // Every declared expected result survives into the plan the candidate carries, one
        // case per generated self-test and one expectation per case (Requirement 10.9).
        let plan = built.baseline.plan()
        #expect(
            plan.cases.map(\.id.rawValue).sorted()
                == built.baseline.selfTests.map(\.caseID.rawValue).sorted(),
            "the plan does not carry every generated self-test case"
        )
        #expect(
            plan.declaredExpectationCount
                == built.baseline.selfTests.reduce(0) { $0 + $1.expectations.count },
            "the plan does not carry every generated expected result"
        )

        // The splicer is faithful: a value replaced and replaced back yields the original
        // bytes, and replacing a value with itself is refused rather than reported as a
        // change. Without this, a neutral control that silently did nothing would look like
        // a passing control.
        let text = String(decoding: built.baseline.integrity.manifestBytes, as: UTF8.self)
        if let forward = ScopedManifestSplice.setting(
            "coreMLModel",
            inObject: "componentVersions",
            to: shape.neutralComponentReplacement,
            of: text
        ) {
            #expect(forward.text != text, "the splice did not change the document")
            let back = ScopedManifestSplice.setting(
                "coreMLModel",
                inObject: "componentVersions",
                to: forward.previousValue,
                of: forward.text
            )
            #expect(back?.text == text, "splicing a value back did not restore the bytes")
        } else {
            report("the neutral member must be spliceable in the baseline manifest")
        }
        #expect(
            ScopedManifestSplice.setting(
                "coreMLModel",
                inObject: "componentVersions",
                to: manifest.componentVersions.coreMLModel.rawValue,
                of: text
            ) == nil,
            "a splice that changes nothing must be refused rather than reported as a change"
        )

        witness.recordCompletenessCheck()
    }

    // MARK: - The digest half

    /// The tree digest a directory artifact's record carries is a function of that tree and
    /// nothing else (Requirement 10.5).
    ///
    /// Quantified over the generated tree rather than a fixed one: enumeration order cannot
    /// change the digest, and no one-member change — added file, added empty directory,
    /// removed member, renamed member, changed byte, duplicated member — leaves it alone. A
    /// digest without both halves would make every artifact check above vacuous.
    func checkTreeDigestsAreDeterministicAndSensitive() {
        guard let built else { return }
        let prefix = CompatibleBundleAssembler.modelTreePath + "/"
        let tree = built.baseline.integrity.tree
        var members: [BundleTreeDigest.Member] = []
        for entry in tree.treeEntries where entry.rawPath.hasPrefix(prefix) {
            let relative = String(entry.rawPath.dropFirst(prefix.count))
            switch entry.kind {
            case .directory:
                members.append(.directory(relativePath: relative))
            case .file:
                let bytes = tree.fileBytes[entry.rawPath] ?? []
                members.append(
                    .file(
                        relativePath: relative,
                        byteCount: UInt64(bytes.count),
                        digest: StreamingSHA256.digest(of: bytes)
                    )
                )
            case .symbolicLink, .other:
                continue
            }
        }
        guard members.count >= 3, case let .file(path, count, digest) = members[0] else {
            report("the generated model tree must hold at least three members")
            return
        }

        // The construction comes from the candidate's own approved canonicalization
        // profile, never named here: a construction spelled in this file would make the
        // arm assert that the test and the profile agree.
        let construction = built.baseline.integrity.canonicalization.construction
        let baseline = Self.treeDigest(members, construction)

        // Deterministic: the same members, in any order, twice.
        #expect(
            Self.treeDigest(members, construction) == baseline,
            "two runs produced different digests"
        )
        #expect(
            Self.treeDigest(members.reversed(), construction) == baseline,
            "enumeration order changed the tree digest"
        )
        #expect(
            Self.treeDigest(members.shuffled(), construction) == baseline,
            "a shuffled enumeration changed the tree digest"
        )

        // Sensitive: six one-member changes, each of which must change the digest.
        var added = members
        added.append(
            .file(
                relativePath: "p26-sensitivity-\(shape.token).bin",
                byteCount: 0,
                digest: StreamingSHA256.digest(of: [])
            )
        )
        #expect(
            Self.treeDigest(added, construction) != baseline,
            "adding a member left the digest alone"
        )

        var addedDirectory = members
        addedDirectory.append(.directory(relativePath: "p26-sensitivity-\(shape.token)"))
        #expect(
            Self.treeDigest(addedDirectory, construction) != baseline,
            "adding an empty directory left the digest alone"
        )

        var removed = members
        removed.removeLast()
        #expect(
            Self.treeDigest(removed, construction) != baseline,
            "removing a member left the digest alone"
        )

        var renamed = members
        renamed[0] = .file(relativePath: path + ".renamed", byteCount: count, digest: digest)
        #expect(
            Self.treeDigest(renamed, construction) != baseline,
            "renaming a member left the digest alone"
        )

        var duplicated = members
        duplicated.append(members[0])
        #expect(
            Self.treeDigest(duplicated, construction) != baseline,
            "duplicating a member left the digest alone"
        )

        var mutated = members
        mutated[0] = .file(
            relativePath: path,
            byteCount: count,
            digest: StreamingSHA256.digest(of: Array("p26-other-bytes".utf8))
        )
        #expect(
            Self.treeDigest(mutated, construction) != baseline,
            "changing a member left the digest alone"
        )

        witness.recordDigestCheck()
    }

    // MARK: - The unrepresentable half

    /// Two ways one declared artifact could appear twice, both refused before a candidate is
    /// assembled (Requirement 10.5).
    ///
    /// The earliest of all the refusals in this file, and worth stating separately: a
    /// manifest that declared the same path twice is not a value at all, and one that
    /// declared a path inside another is refused while the document is parsed — before a
    /// signature is checked or a single artifact byte is read.
    func checkASecondDeclarationOfOneArtifactIsUnrepresentable() {
        guard let built else { return }
        let manifest = built.baseline.integrity.manifest
        guard let first = manifest.artifacts.first else {
            report("the generated baseline must declare at least one artifact")
            return
        }

        // A repeated declared path is not a manifest value.
        #expect(
            throws: ArtifactSchemaError.duplicateEntry(
                field: "manifest.artifacts",
                key: first.path.rawValue
            )
        ) {
            try Sample.manifest(
                bundleID: shape.bundleID,
                artifacts: manifest.artifacts + [first],
                componentVersions: manifest.componentVersions,
                compatibility: manifest.compatibility,
                inputContract: manifest.inputContract,
                outputContract: manifest.outputContract
            )
        }

        // A declared path nested inside another is refused while the manifest is parsed.
        let modelTree = Sample.path(CompatibleBundleAssembler.modelTreePath)
        let nested = Sample.path("\(CompatibleBundleAssembler.modelTreePath)/coremldata.bin")
        guard let nestedBytes = built.baseline.integrity.tree.fileBytes[nested.rawValue],
            !nestedBytes.isEmpty,
            let overlapping = try? Sample.manifest(
                bundleID: shape.bundleID,
                artifacts: manifest.artifacts + [
                    ArtifactDigestRecord(
                        path: nested,
                        kind: .file,
                        byteCount: UInt64(nestedBytes.count),
                        digest: StreamingSHA256.digest(of: nestedBytes)
                    )
                ],
                componentVersions: manifest.componentVersions,
                compatibility: manifest.compatibility,
                inputContract: manifest.inputContract,
                outputContract: manifest.outputContract
            ),
            let bytes = try? BundleAssembler.encode(overlapping)
        else {
            report("an overlapping declared artifact must be describable to be refused")
            return
        }
        #expect(
            Self.parseFinding(bytes, built.baseline)
                == .overlappingDeclaredArtifacts(outer: modelTree, inner: nested),
            "the same bytes cannot carry two digest records"
        )
        // And the baseline's own bytes parse, so the refusal above is the added record.
        #expect(
            Self.parseFinding(built.baseline.integrity.manifestBytes, built.baseline) == nil,
            "the generated baseline manifest must parse under its own policy"
        )

        witness.recordUnrepresentableCheck()
    }

    // MARK: - The mutation half

    /// Over the generated tree, every one-change mutation is refused by name, before
    /// activation, and nothing becomes active.
    ///
    /// Each arm gets its own record store, clock, read log, and activator, so no arm's
    /// outcome can depend on another's. The two controls run in the same loop against the
    /// same harness construction, which is what makes their terminal a control rather than a
    /// separate experiment.
    func checkEveryOneChangeMutationIsRefusedBeforeActivation() async {
        guard let built else { return }

        // The controls first: the unmutated candidate and the neutrally rewritten one must
        // both reach the weight measurement, streaming the weight blob exactly twice.
        for (offset, control) in built.controls.enumerated() {
            let outcome = await Self.attempt(control, bundle: shape.bundleID)
            let label = offset == 0 ? "the unmutated control" : "the neutrally rewritten control"
            guard let finding = outcome.finding else {
                Issue.record(
                    """
                    \(label) activated; no synthetic candidate can pass the required weight \
                    digest
                    """
                )
                continue
            }
            #expect(
                finding == control.expectedFinding,
                "\(label) must reach the weight measurement, got \(finding)"
            )
            #expect(
                outcome.weightBlobReads == built.admittedWeightBlobReads,
                """
                \(label) streamed its weight blob \(outcome.weightBlobReads) time(s), \
                expected \(built.admittedWeightBlobReads); the digest must be measured from \
                bytes twice
                """
            )
            #expect(outcome.activeAfterwards == nil, "\(label) left something active")
            if offset == 0 {
                witness.recordUnmutatedControl()
            } else {
                #expect(
                    control.changedTheCandidate,
                    "the neutral control did not actually rewrite the manifest"
                )
                witness.recordNeutralControl()
            }
        }

        var admitted: [String] = []
        let ordered = shape.orderedMutations
        let byMutation = built.mutations.reduce(into: [BundleMutation: MutationArm]()) {
            $0[$1.mutation] = $1
        }
        #expect(
            ordered.count == BundleMutation.allCases.count,
            "the arm order dropped a mutation"
        )

        for mutation in ordered {
            guard let arm = byMutation[mutation] else {
                report("no arm was built for \(mutation.rawValue)")
                continue
            }

            // The change landed. Without this an arm whose edit silently did nothing would
            // report the control's terminal and look like a refusal.
            #expect(
                arm.changedTheCandidate,
                "\(mutation.rawValue) did not actually change the candidate"
            )
            // And the change is the kind of departure it claims to be. Twenty of the
            // twenty-seven leave the candidate incomplete; seven leave it complete and
            // matching, so their refusals prove the declared-field and approved-bound
            // comparisons are independent of the tree comparison.
            switch mutation.completenessClaim {
            case .staysCompleteAndMatching:
                #expect(
                    arm.measuredDefect == nil,
                    """
                    \(mutation.rawValue) claims to leave a complete, matching bundle but \
                    \(arm.measuredDefect ?? "")
                    """
                )
            case .stopsBeingCompleteAndMatching:
                #expect(
                    arm.measuredDefect != nil,
                    "\(mutation.rawValue) claims to break completeness but the bundle is intact"
                )
            case .declaredSetIsNotDecodable:
                // Completeness is not a question that can be asked of a document with two
                // values for one key. The refusal asserted below is the document-level one,
                // which is the whole content of this arm.
                #expect(
                    arm.expectedFinding.analysisFault
                        == .analysis(.modelLoadError, stage: .modelLoad)
                )
            }
            witness.recordClaim(mutation.completenessClaim)

            let outcome = await Self.attempt(arm, bundle: shape.bundleID)
            guard let finding = outcome.finding else {
                Issue.record("\(mutation.rawValue) activated; the change was not refused")
                admitted.append(mutation.rawValue)
                continue
            }

            #expect(
                finding == arm.expectedFinding,
                "\(mutation.rawValue) must be refused by name, got \(finding)"
            )
            // One category to a session, whichever step refused the candidate.
            #expect(finding.analysisFault == .analysis(.modelLoadError, stage: .modelLoad))
            // Before activation: nothing became active, so nothing is bindable.
            #expect(
                outcome.activeAfterwards == nil,
                "\(mutation.rawValue) was refused but left something active"
            )
            switch arm.weightBlobReads {
            case let .exactly(expected):
                #expect(
                    outcome.weightBlobReads == expected,
                    """
                    \(mutation.rawValue) streamed its weight blob \(outcome.weightBlobReads) \
                    time(s), expected \(expected)
                    """
                )
            case .fewerThanTheAdmittedControl:
                #expect(
                    outcome.weightBlobReads < built.admittedWeightBlobReads,
                    """
                    \(mutation.rawValue) streamed its weight blob \(outcome.weightBlobReads) \
                    time(s); a refused candidate must never reach the compatibility step's \
                    measurement
                    """
                )
            }

            witness.recordRefusal(mutation)
        }

        #expect(admitted.isEmpty, "changes that activated: \(admitted.sorted())")
        witness.recordMutationCheck()
    }

    // MARK: - Running one arm

    private struct Outcome {
        /// The finding one activation produced, or `nil` when it activated.
        let finding: ModelBundleVerificationError?
        let weightBlobReads: Int
        let activeAfterwards: BoundModelBundle?
    }

    /// Attempts one arm through the real activator over its own content store.
    ///
    /// Wrapped rather than rethrown: an error escaping the property body would report a
    /// passing run with every arm skipped.
    private static func attempt(_ arm: MutationArm, bundle: ModelBundleID) async -> Outcome {
        let log = BundleReadLog()
        let content = MultiBundleContentStore(
            trees: [bundle.rawValue: arm.tree],
            recorder: log
        )
        let activator = ActivationHarnessBuilder.activator(
            assembled: arm.assembled,
            content: content,
            store: FakeActivationRecordStore(),
            clock: SteppingClock()
        )
        let finding: ModelBundleVerificationError?
        do {
            _ = try await activator.activate(bundle, context: arm.assembled.context)
            finding = nil
        } catch {
            finding = error
        }
        let needle = "read:\(bundle.rawValue):\(CompatibleBundleAssembler.weightBlobPath)"
        return Outcome(
            finding: finding,
            weightBlobReads: log.work.filter { $0 == needle }.count,
            activeAfterwards: await activator.activeBundle()
        )
    }

    /// The first reason `tree` is not a complete, matching pair with `candidate`'s own
    /// manifest, judged under `candidate`'s own approved canonicalization construction.
    ///
    /// Per candidate rather than against the baseline's manifest: a reassembled variant
    /// declares its own artifacts, and comparing it to another bundle's manifest would
    /// report a defect that is really a difference between two bundles.
    private static func firstDefect(
        _ candidate: CompatibleCandidate,
        tree: FakeBundleTree
    ) -> String? {
        ReferenceBundleCompleteness.firstDefect(
            tree: tree,
            declared: candidate.integrity.manifest.artifacts,
            construction: candidate.integrity.canonicalization.construction
        )
    }

    /// The verified tree of one candidate, or `nil` when integrity refused it.
    private static func verifiedTree(
        _ candidate: CompatibleCandidate
    ) -> VerifiedBundleArtifactTree? {
        try? candidate.integrity.verify()
    }

    /// The finding the real manifest parser produced for `bytes`, or `nil` when it parsed.
    private static func parseFinding(
        _ bytes: [UInt8],
        _ candidate: CompatibleCandidate
    ) -> ModelBundleVerificationError? {
        do {
            _ = try ModelBundleManifestParser.parse(
                bytes,
                for: candidate.integrity.bundleID,
                policy: candidate.integrity.policy
            )
            return nil
        } catch {
            return error
        }
    }

    private static func treeDigest(
        _ members: [BundleTreeDigest.Member],
        _ construction: BundleTreeDigestConstruction
    ) -> DefAIkeDomain.SHA256Digest {
        BundleTreeDigest.digest(of: members, construction: construction)
    }

    /// A copy of `candidate` whose manifest carries one spliced member, re-signed over the
    /// rewritten bytes.
    ///
    /// Re-signing is not optional here. The signature covers the exact manifest bytes, so a
    /// spliced manifest that kept its old signature would be refused for a broken signature
    /// and the arm would stop being about the field it changed.
    private static func spliced(
        _ candidate: CompatibleCandidate,
        member: String,
        inObject object: String,
        to replacement: String
    ) -> CompatibleCandidate? {
        let text = String(decoding: candidate.integrity.manifestBytes, as: UTF8.self)
        guard let result = ScopedManifestSplice.setting(
            member,
            inObject: object,
            to: replacement,
            of: text
        ) else {
            return nil
        }
        var copy = candidate
        copy.integrity.replaceManifest(bytes: Array(result.text.utf8))
        return copy
    }

    /// Whether two trees differ in what they report or in what they hold.
    private static func differs(_ lhs: FakeBundleTree, _ rhs: FakeBundleTree) -> Bool {
        lhs.treeEntries != rhs.treeEntries || lhs.fileBytes != rhs.fileBytes
    }

    // MARK: - Helpers

    private func report(_ message: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        Self.report(message, witness, sourceLocation: sourceLocation)
    }

    /// Records that a fixture this file described could not be built.
    ///
    /// Never a finding about verification: every input here is built from generated
    /// integers inside validated ranges, so a refusal is a defect in this file. It is
    /// counted so a run whose inputs quietly stopped being buildable fails outside the body
    /// rather than shrinking its own coverage.
    private static func report(
        _ message: Comment,
        _ witness: BundleCompletenessWitness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordUnbuildableInput()
        Issue.record(message, sourceLocation: sourceLocation)
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped. Two habits
/// close that gap, and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a
///     floor, so a run in which an arm stopped being reached fails even if the absolute
///     number still looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended
///     early is countable. `completedBodies == cases` alone would pass vacuously as
///     `0 == 0`, which is why the case floor sits beside it.
///
/// The produced sets are the substantive half. Every one of the twenty-seven mutations must
/// actually have been refused by the real verification path on every case, both controls
/// must actually have reached the weight measurement, and every generated table entry must
/// actually have been drawn — which is what turns "any one change is refused" from a claim
/// about unreached branches into a claim about produced outcomes.
private final class BundleCompletenessWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var completenessChecks = 0
    private var digestChecks = 0
    private var unrepresentableChecks = 0
    private var mutationChecks = 0
    private var unmutatedControls = 0
    private var neutralControls = 0
    private var refusals = 0
    private var unbuildableInputs = 0

    // Produced outcomes.
    private var refusedMutations: Set<String> = []
    private var refusedFamilies: Set<String> = []
    private var claimsChecked = 0
    private var checkedClaims: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var bundleIdentifiers: Set<String> = []
    private var weightBlobTokens: Set<String> = []
    private var extraMemberCounts: Set<Int> = []
    private var subdirectoryFlags: Set<Bool> = []
    private var fixtureCounts: Set<Int> = []
    private var declaredFilePaths: Set<String> = []
    private var duplicatedEntryPaths: Set<String> = []
    private var duplicatedKeys: Set<String> = []
    private var comparedComponents: Set<String> = []
    private var noncanonicalForms: Set<String> = []
    private var armOrders: Set<Bool> = []

    func record(_ shape: ManifestTreeShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        bundleIdentifiers.insert(shape.bundleID.rawValue)
        weightBlobTokens.insert(shape.weightBlobToken)
        extraMemberCounts.insert(shape.extraModelMemberCount)
        subdirectoryFlags.insert(shape.addsModelSubdirectory)
        fixtureCounts.insert(shape.fixtureCount)
        declaredFilePaths.insert(shape.declaredFilePath)
        duplicatedEntryPaths.insert(shape.duplicatedEntryPath)
        duplicatedKeys.insert(shape.duplicatedManifestMember.key)
        comparedComponents.insert(shape.comparedComponentMember)
        noncanonicalForms.insert(shape.noncanonicalEntry.form)
        armOrders.insert(shape.armOrderReversed)
    }

    func recordCompletenessCheck() {
        lock.lock()
        completenessChecks += 1
        lock.unlock()
    }

    func recordDigestCheck() {
        lock.lock()
        digestChecks += 1
        lock.unlock()
    }

    func recordUnrepresentableCheck() {
        lock.lock()
        unrepresentableChecks += 1
        lock.unlock()
    }

    func recordMutationCheck() {
        lock.lock()
        mutationChecks += 1
        lock.unlock()
    }

    func recordUnmutatedControl() {
        lock.lock()
        unmutatedControls += 1
        lock.unlock()
    }

    func recordNeutralControl() {
        lock.lock()
        neutralControls += 1
        lock.unlock()
    }

    func recordRefusal(_ mutation: BundleMutation) {
        lock.lock()
        refusals += 1
        refusedMutations.insert(mutation.rawValue)
        refusedFamilies.insert(mutation.family.rawValue)
        lock.unlock()
    }

    func recordClaim(_ claim: CompletenessClaim) {
        lock.lock()
        claimsChecked += 1
        checkedClaims.insert(claim.rawValue)
        lock.unlock()
    }

    func recordUnbuildableInput() {
        lock.lock()
        unbuildableInputs += 1
        lock.unlock()
    }

    /// Called last in the body, so a case that stopped early is countable.
    func recordCompletedBody() {
        lock.lock()
        completedBodies += 1
        lock.unlock()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Every half ran on every case. Compared against the case count rather than against
        // a floor: a half that stopped being reached fails here even when the absolute
        // number still looks large.
        #expect(completenessChecks == cases, "completeness checks: \(completenessChecks)")
        #expect(digestChecks == cases, "tree digest checks: \(digestChecks)")
        #expect(
            unrepresentableChecks == cases,
            "second-declaration checks: \(unrepresentableChecks)"
        )
        #expect(mutationChecks == cases, "mutation checks: \(mutationChecks)")

        // The substantive half: the outcomes were produced, not merely offered.
        #expect(
            unmutatedControls == cases,
            """
            the unmutated candidate reached the weight measurement \(unmutatedControls) \
            time(s); a lower number means the generated baseline is being refused for some \
            other reason
            """
        )
        #expect(
            neutralControls == cases,
            """
            the neutrally rewritten control reached the weight measurement \
            \(neutralControls) time(s); a lower number means splicing and re-signing is \
            itself refusing candidates
            """
        )
        #expect(
            refusals == cases * BundleMutation.allCases.count,
            """
            one-change mutations refused by the real path: \(refusals), expected \
            \(cases * BundleMutation.allCases.count)
            """
        )
        #expect(
            refusedMutations == Set(BundleMutation.allCases.map(\.rawValue)),
            """
            changes never refused: \
            \(Set(BundleMutation.allCases.map(\.rawValue)).subtracting(refusedMutations).sorted())
            """
        )
        #expect(
            refusedFamilies == Set(MutationFamily.allCases.map(\.rawValue)),
            """
            change families never refused: \
            \(Set(MutationFamily.allCases.map(\.rawValue)).subtracting(refusedFamilies).sorted())
            """
        )
        // Every change was also checked against the completeness claim it makes, and all
        // three kinds of claim were exercised: a bundle that stopped being complete, one
        // that stayed complete and was refused on a declared field or an approved bound, and
        // one whose declared set is not decodable at all.
        #expect(
            claimsChecked == cases * BundleMutation.allCases.count,
            "completeness claims checked: \(claimsChecked)"
        )
        #expect(
            checkedClaims == Set(CompletenessClaim.allCases.map(\.rawValue)),
            """
            completeness claims never exercised: \
            \(Set(CompletenessClaim.allCases.map(\.rawValue)).subtracting(checkedClaims).sorted())
            """
        )

        // The generated baseline actually varied, and every table entry was drawn.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            bundleIdentifiers.count >= 50,
            "generated bundle identifiers: \(bundleIdentifiers.count)"
        )
        #expect(
            weightBlobTokens.count >= 50,
            "generated weight-blob contents: \(weightBlobTokens.count)"
        )
        #expect(extraMemberCounts == [0, 1, 2], "generated extra member counts: \(extraMemberCounts.sorted())")
        #expect(subdirectoryFlags == [false, true], "only one subdirectory choice was generated")
        #expect(fixtureCounts == [2, 3], "generated fixture counts: \(fixtureCounts.sorted())")
        #expect(
            declaredFilePaths == Set(ManifestTreeShape.declaredFilePaths),
            "generated declared file paths: \(declaredFilePaths.sorted())"
        )
        #expect(
            duplicatedEntryPaths.count == 4,
            "generated duplicated entry paths: \(duplicatedEntryPaths.sorted())"
        )
        #expect(
            duplicatedKeys == ["artifacts", "bundleID", "schemaVersion", "signingKey"],
            "generated duplicated manifest keys: \(duplicatedKeys.sorted())"
        )
        #expect(
            comparedComponents == [
                "calibrationPolicy", "evidenceScope", "preprocessingContract",
                "verdictCopyCompatibility",
            ],
            "generated compared components: \(comparedComponents.sorted())"
        )
        #expect(
            noncanonicalForms == [
                "absolute", "backslash", "current-directory", "embedded-space",
                "empty-component", "traversal",
            ],
            "generated noncanonical path forms: \(noncanonicalForms.sorted())"
        )
        #expect(armOrders == [false, true], "only one arm order was generated")
    }
}
