import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Design Property 2: sole pixel-model identity.
//
// The design states it as: for any local Model Bundle catalog and candidate activation,
// pixel inference can bind only a bundle whose model identity is exactly the Lowq
// checkpoint, whose model format is the compatible FP16 `mlprogram`, and whose declared
// weight digest equals the required digest; every other identity or incompatible artifact
// is rejected.
//
// Four pinned facts, five pinned leaves. Requirement 10.2 fixes the checkpoint identity,
// Requirement 10.3 fixes the program kind, the compute precision, and the minimum
// deployment target, Requirement 10.4 fixes the weight-blob digest, and Requirement 1.16
// makes that one model the sole pixel-analysis model for every route and quality
// condition. This file generates a local catalog per case, mutates exactly one of those
// leaves per catalogued candidate, and quantifies four halves over it:
//
//   * **the constant half** — the values the production code pins are the values the
//     requirements name, and every generated mutant really is outside that set. Without
//     this, every refusal below would be measured against whatever the code happened to
//     carry (Requirements 10.2, 10.3, 10.4);
//   * **the schema half** — a candidate declaring any other checkpoint, weight digest,
//     program kind, precision, or deployment target is not a manifest value at all, and
//     the required combination is (Requirements 1.16, 10.2, 10.3, 10.4);
//   * **the catalog half** — over the generated catalog, the real integrity and
//     compatibility verifiers reached through the real activator admit only the exact
//     compatible Lowq candidate as far as the weight measurement. Every mutant is refused
//     earlier, by name, nothing becomes active, and pixel inference stays prevented
//     (Requirements 10.2, 10.3, 10.4);
//   * **the load half** — the value the Core ML adapter must produce before inference can
//     run is constructible for the required identity and for no other one
//     (Requirement 1.16). `CoreMLPixelModelLoader` lives in `DefAIkeCoreML`, outside this
//     test target's module closure; `PixelModelLoadingTests` pins the adapter's own
//     outcomes at examples, and this file quantifies the identity gate the adapter has to
//     pass through over generated identities.
//
// ## Why the pass signal is a refusal, and what that costs
//
// Requirement 10.4 pins the weight-blob digest to one specific SHA-256 value, so passing
// the weight measurement requires the actual approved weight blob. That artifact is not in
// this repository, and fabricating a digest would disable the one check that pins model
// identity to bytes. So the exact compatible Lowq candidate stops at
// `modelWeightDigestMismatch`, and that finding is this file's "everything before it
// passed" signal — the same signal `ModelIdentityAndCompatibilityTests` uses at examples.
// Two observations keep it from being a vacuous stopping point:
//
//   * the weight blob is streamed twice for an admitted candidate — once while the
//     integrity step hashes the declared model tree, once by the compatibility step's own
//     measurement — so the digest is measured from bytes rather than read from the
//     manifest; and
//   * the generated weight-blob content varies per case, so the refusal is quantified over
//     content rather than asserted about one fixture blob.
//
// Whether the real released blob hashes to the required value is an integration question
// against the real immutable artifact, and it belongs to task 6.11. Nothing here is
// release evidence: every policy, identifier, fixture, digest, and key below is synthetic
// and exists so a verifier that takes approved inputs can be called at all. No signature
// algorithm ran, no compiled model was loaded, and no fixture parity was measured.
//
// ## What this file does not assert
//
//   * That a session keeps its snapshot across a later activation, or that a report states
//     the bound versions. That is Property 13's statement.
//   * What one prediction's output maps to. That is Property 14's.
//   * Whether a manifest's artifact inventory is complete and mutation-sensitive, or
//     whether activation and rollback are atomic under injected failures. Those are
//     Properties 26 and 27. The catalog half asserts only that nothing became active,
//     which is the part Property 2 needs in order to say "cannot bind".
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: every
// throwing assembler, verifier, and activator call is wrapped into a value or reported
// through `Issue.record`, and ``SolePixelModelWitness`` counts the cases and every arm
// *outside* the body, where an issue is not suppressed. The arm counters are compared
// against the case count rather than against a floor, and the last thing the body does is
// record that it reached the end, so a case that stopped early is countable.

extension Tag {
    /// Design Property 2.
    ///
    /// Declared here rather than in a shared tag namespace: each design property gets one
    /// dedicated file, and a shared namespace would be a merge point between property
    /// files written independently of each other.
    @Tag static var property2SolePixelModelIdentity: Self
}

@Suite(
    "Property 2: sole pixel-model identity",
    .tags(.property2SolePixelModelIdentity)
)
struct SolePixelModelIdentityPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is
    /// composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 1.16, 10.2, 10.3, 10.4**
    @Test("Only the exact compatible Lowq candidate can be bound for pixel inference")
    func onlyTheLowqCheckpointCanBind() async {
        let witness = SolePixelModelWitness()

        await propertyCheck(input: ModelCatalogShape.generator) { shape in
            witness.record(shape)

            let scenario = SolePixelModelScenario.checkedConstants(shape, witness: witness)
            scenario.checkTheSchemasAdmitOnlyTheRequiredModel()
            scenario.checkOnlyTheRequiredIdentityIsBindableForInference()
            await scenario.checkOnlyTheExactLowqCandidateReachesTheWeightMeasurement()

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The reference model

/// The four pinned facts, written from the requirements rather than from the code under
/// test.
///
/// Small on purpose. Its value is that it restates Requirement 10.2's checkpoint string,
/// Requirement 10.3's format sentence, and Requirement 10.4's digest literally, so the
/// comparison is against the requirement rather than against a second reading of the
/// implementation. If a production constant ever drifts, the constant half fails here
/// instead of every refusal below quietly measuring the drifted value.
private enum ReferenceSolePixelModel {
    /// Requirement 10.2.
    static let checkpointIdentifier =
        "Thermostatic/community-forensics-low-quality-detector-2026-08"

    /// Requirement 10.4.
    static let weightDigestHexadecimal =
        "f073f8a325f63e35ef0668c985ac762486a1b50e57dcf5ae33d4647bd26d4c1e"

    /// Requirement 10.3, as the three leaves a manifest declares it in.
    static let programKind = "mlprogram"
    static let computePrecision = "float16"
    static let minimumDeploymentTarget = "17.0.0"

    /// Whether a candidate declaring these five values is the sole permitted pixel model.
    ///
    /// A conjunction, deliberately: Requirement 1.16 admits one model, so weakening any
    /// single leaf is enough to put a candidate outside the set.
    static func isSolePermittedPixelModel(
        checkpointIdentifier: String,
        weightDigestHexadecimal: String,
        programKind: String,
        computePrecision: String,
        minimumDeploymentTarget: String
    ) -> Bool {
        checkpointIdentifier == Self.checkpointIdentifier
            && weightDigestHexadecimal == Self.weightDigestHexadecimal
            && programKind == Self.programKind
            && computePrecision == Self.computePrecision
            && minimumDeploymentTarget == Self.minimumDeploymentTarget
    }
}

// MARK: - What one candidate mutates

/// The five pinned manifest leaves, one per way a candidate can stop being the sole
/// permitted pixel model.
///
/// Five leaves across the four requirement facts: the format fact spans three of them.
/// Each is a separately declared member of the signed manifest, so each can be spliced on
/// its own and the resulting finding names one cause.
private enum PinnedModelField: String, Hashable, Sendable, CaseIterable {
    case checkpointIdentity = "checkpoint-identity"
    case requiredWeightDigest = "required-weight-digest"
    case programKind = "program-kind"
    case computePrecision = "compute-precision"
    case minimumDeploymentTarget = "minimum-deployment-target"

    /// The top-level manifest object the leaf lives in.
    var enclosingObject: String {
        switch self {
        case .checkpointIdentity, .requiredWeightDigest: "modelIdentity"
        case .programKind, .computePrecision, .minimumDeploymentTarget: "modelFormat"
        }
    }

    /// The member name inside that object.
    var member: String {
        switch self {
        case .checkpointIdentity: "checkpointIdentifier"
        case .requiredWeightDigest: "requiredWeightDigest"
        case .programKind: "programKind"
        case .computePrecision: "computePrecision"
        case .minimumDeploymentTarget: "minimumOS"
        }
    }
}

/// One candidate's place in a generated catalog.
private enum CatalogRole: Hashable, Sendable {
    /// The exact compatible Lowq candidate. Unspliced.
    case reference

    /// Spliced in a member no pinned fact covers, so it still resolves.
    ///
    /// The control that makes every refusal below attributable to the pinned leaf rather
    /// than to the act of rewriting and re-signing a manifest.
    case neutrallySpliced

    /// Spliced in exactly one pinned leaf.
    case pinnedFieldMutated(PinnedModelField)

    /// Installed locally and structurally perfect, but absent from the approved catalogue
    /// the running build binds.
    case uncatalogued

    /// Every catalogued role a generated catalog carries, in declaration order.
    ///
    /// ``uncatalogued`` is deliberately outside this list: a candidate the signed catalogue
    /// lists is what "catalogued" means, so the uncatalogued one is attempted alongside the
    /// catalog rather than inside it.
    static let all: [CatalogRole] =
        [.reference, .neutrallySpliced]
        + PinnedModelField.allCases.map(CatalogRole.pinnedFieldMutated)

    /// A canonical token for the bundle identifier and for failure messages.
    var token: String {
        switch self {
        case .reference: "reference"
        case .neutrallySpliced: "neutral"
        case .pinnedFieldMutated(let field): field.rawValue
        case .uncatalogued: "uncatalogued"
        }
    }

    /// How many times this candidate's weight blob is streamed during one attempt.
    ///
    /// Two for a candidate that reaches the measurement: once while the integrity step
    /// hashes the declared model tree, once by the compatibility step's own measurement.
    /// One for the uncatalogued candidate, whose integrity step completes before catalogue
    /// membership is refused. Zero for a candidate refused while its manifest is parsed,
    /// because nothing else has been read yet. The differences are what make "the digest was
    /// measured from bytes" and "the refusal came before the measurement" observable rather
    /// than assumed.
    var expectedWeightBlobReadCount: Int {
        switch self {
        case .reference, .neutrallySpliced: 2
        case .uncatalogued: 1
        case .pinnedFieldMutated: 0
        }
    }
}

// MARK: - Generated shape

/// One generated Model Bundle catalog.
///
/// Every field is a bounded integer or a flag, and each mutant value is read off the shape
/// by modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct ModelCatalogShape: Sendable, CustomStringConvertible {
    /// Drives the generated weight-blob content and the neutral component version, so a
    /// case's values vary together and a failing case names one seed.
    let seed: Int

    let checkpointIndex: Int
    let digestPositionIndex: Int
    let digestShiftIndex: Int
    let programKindIndex: Int
    let precisionIndex: Int
    let deploymentTargetIndex: Int

    /// Whether the catalog is activated in reverse declaration order.
    ///
    /// The activator is stateful — it holds the active pointer and an activation
    /// generation — so exercising both orders is what shows that no member's refusal
    /// depends on which member was attempted first.
    let catalogOrderReversed: Bool

    /// Whether the locally installed uncatalogued bundle is attempted before the catalog.
    let strangerRunsFirst: Bool

    // MARK: The mutant values

    /// A canonical checkpoint identifier that is not the Lowq one.
    ///
    /// Near misses on purpose: one date digit, one letter case, one word, and a suffix.
    /// A verifier that compared checkpoints loosely would accept one of these, and the
    /// unrelated namespace alone would not catch it.
    var mutantCheckpointIdentifier: String {
        let table = [
            "Thermostatic/community-forensics-low-quality-detector-2026-09",
            "Thermostatic/community-forensics-low-quality-detector-2026-07",
            "thermostatic/community-forensics-low-quality-detector-2026-08",
            "Thermostatic/community-forensics-high-quality-detector-2026-08",
            "Other/community-forensics-low-quality-detector-2026-08",
            "\(ReferenceSolePixelModel.checkpointIdentifier)-\(1 + seed % 999)",
        ]
        return table[checkpointIndex % table.count]
    }

    /// A canonical lowercase hexadecimal digest that is not the required one.
    ///
    /// Built by rotating exactly one nibble of the required digest, so it stays a valid
    /// 64-character digest and differs by the smallest amount a digest can differ by. A
    /// wholly unrelated value would not distinguish "compared the digest" from "compared
    /// its length".
    var mutantWeightDigestHexadecimal: String {
        let digits = Array("0123456789abcdef")
        var characters = Array(ReferenceSolePixelModel.weightDigestHexadecimal)
        let position = digestPositionIndex % characters.count
        guard let current = digits.firstIndex(of: characters[position]) else {
            return String(repeating: "0", count: characters.count)
        }
        let shift = 1 + digestShiftIndex % 15
        characters[position] = digits[(current + shift) % digits.count]
        return String(characters)
    }

    /// A program kind that is not `mlprogram`.
    ///
    /// The vocabulary has exactly three members, so the mutant space is the other two and
    /// the table is the whole space rather than a sample of it.
    var mutantProgramKind: ModelProgramKind {
        let table: [ModelProgramKind] = [.neuralNetwork, .pipeline]
        return table[programKindIndex % table.count]
    }

    /// A compute precision that is not `float16`.
    ///
    /// One entry, because ``ModelComputePrecision`` has exactly two members. Kept as a
    /// table so that adding a third precision has to extend it rather than silently go
    /// ungenerated.
    var mutantComputePrecision: ModelComputePrecision {
        let table: [ModelComputePrecision] = [.float32]
        return table[precisionIndex % table.count]
    }

    /// A canonical platform version that is not 17.0.0.
    ///
    /// Below, above, and adjacent in each component: a check that accepted "at least 17"
    /// rather than "exactly 17.0.0" would pass on three of these.
    var mutantDeploymentTargetToken: String {
        let table = ["16.0.0", "17.0.1", "17.1.0", "18.0.0", "26.0.0"]
        return table[deploymentTargetIndex % table.count]
    }

    /// A canonical artifact version for the neutral splice.
    ///
    /// The Core ML component version is the one manifest member compatibility deliberately
    /// does not compare against a build-side identifier, so changing it is a rewrite that
    /// must not change the outcome.
    var neutralComponentVersionToken: String { "component.core-ml-model-\(1 + seed % 999)" }

    // MARK: The generated weight blob

    /// Eleven bytes of synthetic weight-blob content.
    ///
    /// Exactly the length of the assembler's own placeholder, because the declared tree
    /// record is derived from the tree after this replacement while the enumeration still
    /// reports the original size; a different length would make the candidate fail on a
    /// size mismatch instead of on its digest. Nothing about the content matters beyond
    /// varying per case, and no synthetic content can hash to the required digest — that is
    /// the check working, not a gap.
    var weightBlobBytes: [UInt8] {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = Array("weight-".utf8)
        var value = UInt64(bitPattern: Int64(seed)) &* 2_654_435_761 &+ 1
        for _ in 0..<4 {
            bytes.append(digits[Int(value & 0xF)])
            value >>= 4
        }
        return bytes
    }

    var weightBlobToken: String { String(decoding: weightBlobBytes, as: UTF8.self) }

    // MARK: Identifiers

    func bundleID(for role: CatalogRole) -> ModelBundleID {
        Sample.bundle("bundle.p2-\(role.token)")
    }

    /// A locally installed bundle the approved catalog does not list.
    ///
    /// The catalog quantifier's other edge: installed and structurally perfect is not the
    /// same as catalogued, and a candidate outside the signed catalogue cannot bind however
    /// correct its identity is.
    var uncataloguedBundleID: ModelBundleID { Sample.bundle("bundle.p2-uncatalogued") }

    /// Every catalogued bundle identifier, in activation order.
    var orderedRoles: [CatalogRole] {
        catalogOrderReversed ? CatalogRole.all.reversed() : CatalogRole.all
    }

    var catalogueIdentifiers: [ModelBundleID] { CatalogRole.all.map(bundleID(for:)) }

    // MARK: Description

    var description: String {
        """
        seed \(seed), checkpoint "\(mutantCheckpointIdentifier)", \
        digest \(mutantWeightDigestHexadecimal), \
        program kind \(mutantProgramKind.rawValue), \
        precision \(mutantComputePrecision.rawValue), \
        deployment target \(mutantDeploymentTargetToken), \
        neutral component "\(neutralComponentVersionToken)", \
        weight blob "\(weightBlobToken)", \
        reversed \(catalogOrderReversed), stranger first \(strangerRunsFirst)
        """
    }

    // MARK: Generator

    static var generator: Generator<ModelCatalogShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            index,
            index,
            index,
            index,
            index,
            index,
            Gen.bool,
            Gen.bool
        )
        .map { raw in
            ModelCatalogShape(
                seed: raw.0,
                checkpointIndex: raw.1,
                digestPositionIndex: raw.2,
                digestShiftIndex: raw.3,
                programKindIndex: raw.4,
                precisionIndex: raw.5,
                deploymentTargetIndex: raw.6,
                catalogOrderReversed: raw.7,
                strangerRunsFirst: raw.8
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (1, 2, 5, 6, 15, 64), so
    /// each table entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...959).eraseToAny()
    }
}

// MARK: - Scoped manifest splicing

/// Replaces the string value of one member inside one top-level object member of a signed
/// manifest, leaving every other byte untouched.
///
/// Text splicing rather than a `JSONSerialization` round trip, for the reason
/// `JSONMemberSplice` records in the domain tests: re-serializing a value perturbs its
/// exact decimals, and a Model Bundle manifest carries one — the upstream boundary value
/// the Calibration Policy pins — so a refusal after a round trip could come from the
/// perturbed decimal instead of from the field the arm is about.
///
/// Scoped rather than global, because `minimumOS` appears twice in a manifest: once in the
/// model format and once in the compatibility matrix. A global substitution would change
/// two fields at once and the finding would no longer name one cause.
///
/// Every refusal returns `nil` rather than the unchanged text, so an arm cannot assert
/// against a manifest it did not actually mutate.
private enum ManifestMemberSplice {
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

// MARK: - One generated catalog

/// One catalogued candidate: its identifier, its role, and the finding verification must
/// produce for it.
private struct CatalogedCandidate {
    let role: CatalogRole
    let bundleID: ModelBundleID
    let expectedFinding: ModelBundleVerificationError
    let expectedWeightBlobReadCount: Int
}

/// One generated catalog, the approved inputs one build binds, and the real activator over
/// it.
///
/// The verifiers and the activator are the production ones. The approved configuration,
/// evidence scope, layout, verification policy, signature stand-in, and running context all
/// come from the reference candidate, so the whole catalog is judged by one build's approved
/// inputs rather than by each candidate's own.
private struct SolePixelModelScenario {
    let shape: ModelCatalogShape
    let witness: SolePixelModelWitness

    /// Present only when every fixture this case describes was buildable.
    private let assembled: Assembled?

    private struct Assembled {
        let reference: CompatibleCandidate
        let candidates: [CatalogedCandidate]
        let uncatalogued: CatalogedCandidate
        let readLog: BundleReadLog
        let activator: ModelBundleActivator
        let context: ReleaseContext
        let weightBlobPath: String
    }

    /// One generated model format and the schema refusal it must produce.
    private struct MutantFormat {
        let programKind: ModelProgramKind
        let computePrecision: ModelComputePrecision
        let minimumOS: PlatformVersion
        let refusal: ArtifactSchemaError
    }

    // MARK: - The constant half

    /// Builds the scenario after confirming the pinned constants and the generated mutants.
    ///
    /// The constant check runs first because every later refusal is measured against these
    /// values: if a production constant ever drifts from the requirement text, this fails
    /// here rather than letting the rest of the file quietly certify the drifted value
    /// (Requirements 10.2, 10.3, 10.4).
    static func checkedConstants(
        _ shape: ModelCatalogShape,
        witness: SolePixelModelWitness
    ) -> SolePixelModelScenario {
        #expect(
            RequiredPixelModel.checkpointIdentifier
                == ReferenceSolePixelModel.checkpointIdentifier,
            "the pinned checkpoint identity is not the one Requirement 10.2 names"
        )
        #expect(
            RequiredPixelModel.weightDigestHexadecimal
                == ReferenceSolePixelModel.weightDigestHexadecimal,
            "the pinned weight digest is not the one Requirement 10.4 names"
        )
        #expect(
            RequiredPixelModel.identity.checkpointIdentifier.rawValue
                == ReferenceSolePixelModel.checkpointIdentifier
        )
        #expect(
            RequiredPixelModel.identity.requiredWeightDigest.hexadecimalString
                == ReferenceSolePixelModel.weightDigestHexadecimal
        )
        #expect(ModelProgramKind.mlProgram.rawValue == ReferenceSolePixelModel.programKind)
        #expect(
            ModelComputePrecision.float16.rawValue == ReferenceSolePixelModel.computePrecision
        )
        #expect(
            PlatformVersion.iOS17.description
                == ReferenceSolePixelModel.minimumDeploymentTarget
        )

        // The required combination is the sole permitted one, and each generated mutant
        // leaves it. Without this, a generator that happened to produce the required value
        // would make an "is rejected" arm assert the opposite of what it reads.
        #expect(
            ReferenceSolePixelModel.isSolePermittedPixelModel(
                checkpointIdentifier: ReferenceSolePixelModel.checkpointIdentifier,
                weightDigestHexadecimal: ReferenceSolePixelModel.weightDigestHexadecimal,
                programKind: ReferenceSolePixelModel.programKind,
                computePrecision: ReferenceSolePixelModel.computePrecision,
                minimumDeploymentTarget: ReferenceSolePixelModel.minimumDeploymentTarget
            )
        )
        for field in PinnedModelField.allCases {
            #expect(
                shape.leavesTheSolePermittedModel(field),
                "the generated \(field.rawValue) mutant must be outside the required set"
            )
        }

        witness.recordConstantCheck()
        return SolePixelModelScenario(
            shape: shape,
            witness: witness,
            assembled: Self.assemble(shape, witness: witness)
        )
    }

    // MARK: - The schema half

    /// A candidate declaring any other identity, format, or deployment target is not a
    /// manifest value at all (Requirements 1.16, 10.2, 10.3, 10.4).
    ///
    /// The verifier checks all three too — the catalog half exercises that path — so this is
    /// the first of two independent refusals rather than a substitute for it. It matters on
    /// its own because it establishes that such a candidate cannot even *become* a manifest,
    /// which is why the catalog half sees a schema finding rather than a compatibility one.
    func checkTheSchemasAdmitOnlyTheRequiredModel() {
        // The positive control for both refusal groups below: the required combination is
        // accepted, so the refusals are about the mutated leaf rather than about the
        // fixture being unbuildable.
        #expect(throws: Never.self) { try Self.manifest(declaring: RequiredPixelModel.identity) }
        #expect(throws: Never.self) {
            try ModelFormatDescriptor(
                programKind: .mlProgram,
                computePrecision: .float16,
                minimumOS: .iOS17
            )
        }

        // Named rather than inferred from the loop: a generated checkpoint or digest that
        // stopped being constructible would otherwise silently shrink this arm's coverage,
        // and the witness would report a count without naming the cause.
        let identities = shape.mutantIdentities
        guard identities.count == ModelCatalogShape.mutantIdentityCount else {
            report("every generated mutant identity must be constructible")
            return
        }
        for identity in identities {
            #expect(identity != RequiredPixelModel.identity)
            #expect(throws: Self.identityRefusal(for: identity)) {
                try Self.manifest(declaring: identity)
            }
            witness.recordSchemaIdentityRefusal()
        }

        guard let mutantVersion = try? PlatformVersion(
            validating: shape.mutantDeploymentTargetToken
        ) else {
            report("the generated deployment target must be a canonical platform version")
            return
        }
        #expect(mutantVersion != .iOS17)

        // One leaf at a time, because the format descriptor reports the first disagreement
        // it finds: a candidate weakening two leaves would name only one of them, and the
        // arm would stop distinguishing which leaf was checked.
        let formats: [MutantFormat] = [
            MutantFormat(
                programKind: shape.mutantProgramKind,
                computePrecision: .float16,
                minimumOS: .iOS17,
                refusal: .fixedValueMismatch(
                    field: "modelFormat.programKind",
                    expected: ReferenceSolePixelModel.programKind,
                    found: shape.mutantProgramKind.rawValue
                )
            ),
            MutantFormat(
                programKind: .mlProgram,
                computePrecision: shape.mutantComputePrecision,
                minimumOS: .iOS17,
                refusal: .fixedValueMismatch(
                    field: "modelFormat.computePrecision",
                    expected: ReferenceSolePixelModel.computePrecision,
                    found: shape.mutantComputePrecision.rawValue
                )
            ),
            MutantFormat(
                programKind: .mlProgram,
                computePrecision: .float16,
                minimumOS: mutantVersion,
                refusal: .fixedValueMismatch(
                    field: "modelFormat.minimumOS",
                    expected: ReferenceSolePixelModel.minimumDeploymentTarget,
                    found: mutantVersion.description
                )
            ),
        ]
        for format in formats {
            #expect(throws: format.refusal) {
                try ModelFormatDescriptor(
                    programKind: format.programKind,
                    computePrecision: format.computePrecision,
                    minimumOS: format.minimumOS
                )
            }
            witness.recordSchemaFormatRefusal()
        }
        #expect(formats.count == ModelCatalogShape.mutantFormatCount)
        witness.recordSchemaCheck()
    }

    // MARK: - The load half

    /// The value pixel inference runs against is constructible for the required identity and
    /// for no other one (Requirement 1.16).
    ///
    /// This is the last boundary before a prediction: the Core ML adapter cannot hand the
    /// analyzer anything else, because there is no other way to build the value and its
    /// initializer refuses every identity but one. Asserted with the accepted arm beside the
    /// refused ones, so "returns nothing" is backed by an initializer that provably does
    /// return something when the identity is right.
    func checkOnlyTheRequiredIdentityIsBindableForInference() {
        #expect(
            Self.loadedModel(identity: RequiredPixelModel.identity) != nil,
            "the sole permitted pixel model must be bindable for inference"
        )
        witness.recordAcceptedLoadIdentity()

        for identity in shape.mutantIdentities {
            #expect(
                Self.loadedModel(identity: identity) == nil,
                "\(identity.checkpointIdentifier.rawValue) must not be bindable for inference"
            )
            witness.recordRefusedLoadIdentity()
        }

        // And a bundle cannot supply another identity in the first place: the identity a
        // loaded model carries comes from the signed manifest, whose schema admits one.
        if let assembled {
            #expect(assembled.reference.integrity.manifest.modelIdentity
                == RequiredPixelModel.identity)
        }
        witness.recordLoadBoundaryCheck()
    }

    // MARK: - The catalog half

    /// Over the generated catalog, only the exact compatible Lowq candidate reaches the
    /// weight measurement; every other candidate is refused earlier, by name, and nothing
    /// becomes active (Requirements 10.2, 10.3, 10.4).
    func checkOnlyTheExactLowqCandidateReachesTheWeightMeasurement() async {
        guard let assembled else { return }

        var admitted: [String] = []
        var attempts = assembled.candidates
        if shape.strangerRunsFirst {
            attempts.insert(assembled.uncatalogued, at: 0)
        } else {
            attempts.append(assembled.uncatalogued)
        }
        #expect(
            attempts.count == CatalogRole.all.count + 1,
            "the catalog offered \(attempts.count) candidates plus the uncatalogued one"
        )

        for candidate in attempts {
            let before = assembled.readLog.work.count
            let finding = await Self.activationFinding(
                assembled.activator,
                candidate.bundleID,
                assembled.context
            )
            let weightReads = assembled.readLog.work[before...].filter {
                $0 == "read:\(candidate.bundleID.rawValue):\(assembled.weightBlobPath)"
            }

            guard let finding else {
                Issue.record(
                    """
                    \(candidate.role.token) activated; no synthetic candidate can pass the \
                    required weight digest
                    """
                )
                admitted.append(candidate.role.token)
                continue
            }

            #expect(
                finding == candidate.expectedFinding,
                "\(candidate.role.token) must be refused by name, got \(finding)"
            )
            // Every refusal that concerns the bundle is one category to a session: pixel
            // inference is prevented and the terminal is `model-load-error`.
            #expect(finding.analysisFault == .analysis(.modelLoadError, stage: .modelLoad))
            // Nothing became active, so nothing is bindable for inference.
            #expect(await assembled.activator.activeBundle() == nil)
            #expect(
                weightReads.count == candidate.expectedWeightBlobReadCount,
                """
                \(candidate.role.token) streamed its weight blob \(weightReads.count) \
                time(s), expected \(candidate.expectedWeightBlobReadCount)
                """
            )

            switch candidate.role {
            case .reference:
                witness.recordReferenceTerminal()
            case .neutrallySpliced:
                witness.recordNeutralControlTerminal()
            case .pinnedFieldMutated(let field):
                witness.recordPinnedFieldRefusal(field)
            case .uncatalogued:
                witness.recordUncataloguedRefusal()
            }
        }

        #expect(admitted.isEmpty, "candidates that activated: \(admitted)")

        // The port-level statement of the same outcome: no verified compatible bundle is
        // active, so the manager prevents pixel inference and reports `model-load-error`.
        #expect(await assembled.activator.activeBundle() == nil)
        #expect(
            await Self.verifiedActiveFinding(assembled.activator, assembled.context)
                == .noActiveModelBundle
        )
        #expect(
            await Self.portFault(assembled.activator, assembled.context)
                == .analysis(.modelLoadError, stage: .modelLoad)
        )
        witness.recordCatalogCheck()
    }

    // MARK: - Assembly

    private static func assemble(
        _ shape: ModelCatalogShape,
        witness: SolePixelModelWitness
    ) -> Assembled? {
        let catalogue = shape.catalogueIdentifiers
        var trees: [String: FakeBundleTree] = [:]
        var candidates: [CatalogedCandidate] = []
        var reference: CompatibleCandidate?

        for role in shape.orderedRoles {
            guard var candidate = try? CompatibleBundleAssembler.standard(
                bundleID: shape.bundleID(for: role),
                bundleCatalog: catalogue,
                treeOverrides: { tree in
                    tree.overwriteContent(
                        CompatibleBundleAssembler.weightBlobPath,
                        bytes: shape.weightBlobBytes
                    )
                }
            ) else {
                Self.report("a structurally valid candidate must be assemblable", witness)
                return nil
            }

            let expected: ModelBundleVerificationError
            switch role {
            case .reference:
                reference = candidate
                expected = .modelWeightDigestMismatch(candidate.layout.modelWeightBlob)
            case .neutrallySpliced:
                guard Self.splice(
                    "coreMLModel",
                    inObject: "componentVersions",
                    to: shape.neutralComponentVersionToken,
                    of: &candidate
                ) else {
                    Self.report("the neutral member must be spliceable", witness)
                    return nil
                }
                expected = .modelWeightDigestMismatch(candidate.layout.modelWeightBlob)
            case .pinnedFieldMutated(let field):
                guard Self.splice(
                    field.member,
                    inObject: field.enclosingObject,
                    to: shape.replacement(for: field),
                    of: &candidate
                ) else {
                    Self.report("\(field.rawValue) must be spliceable", witness)
                    return nil
                }
                expected = .manifestRejectedBySchema(shape.schemaRefusal(for: field))
            case .uncatalogued:
                // Not a catalogued role, so ``CatalogRole/all`` never yields it. Reaching
                // here would mean this file put an uncatalogued candidate inside the
                // approved catalogue, which is the opposite of what that role means.
                Self.report("the uncatalogued role is not a catalogued candidate", witness)
                return nil
            }

            trees[candidate.integrity.bundleID.rawValue] = candidate.integrity.tree
            candidates.append(
                CatalogedCandidate(
                    role: role,
                    bundleID: candidate.integrity.bundleID,
                    expectedFinding: expected,
                    expectedWeightBlobReadCount: role.expectedWeightBlobReadCount
                )
            )
        }

        guard let reference else {
            Self.report("the reference candidate must be present in every catalog", witness)
            return nil
        }

        // Installed and structurally perfect, but absent from the approved catalogue the
        // reference build binds. Assembled with the same overrides so the only thing that
        // distinguishes it is catalogue membership.
        guard let stranger = try? CompatibleBundleAssembler.standard(
            bundleID: shape.uncataloguedBundleID,
            bundleCatalog: catalogue,
            treeOverrides: { tree in
                tree.overwriteContent(
                    CompatibleBundleAssembler.weightBlobPath,
                    bytes: shape.weightBlobBytes
                )
            }
        ) else {
            Self.report("the uncatalogued candidate must be assemblable", witness)
            return nil
        }
        trees[shape.uncataloguedBundleID.rawValue] = stranger.integrity.tree

        let readLog = BundleReadLog()
        let content = MultiBundleContentStore(trees: trees, recorder: readLog)
        return Assembled(
            reference: reference,
            candidates: candidates,
            uncatalogued: CatalogedCandidate(
                role: .uncatalogued,
                bundleID: shape.uncataloguedBundleID,
                expectedFinding: .candidateNotInApprovedBundleCatalog(shape.uncataloguedBundleID),
                expectedWeightBlobReadCount: CatalogRole.uncatalogued
                    .expectedWeightBlobReadCount
            ),
            readLog: readLog,
            activator: ActivationHarnessBuilder.activator(
                assembled: reference,
                content: content,
                store: FakeActivationRecordStore(),
                clock: SteppingClock()
            ),
            context: reference.context,
            weightBlobPath: CompatibleBundleAssembler.weightBlobPath
        )
    }

    /// Splices one manifest member and re-signs, so the failure under test is the spliced
    /// field rather than the broken signature it would otherwise cause.
    private static func splice(
        _ member: String,
        inObject object: String,
        to replacement: String,
        of candidate: inout CompatibleCandidate
    ) -> Bool {
        let text = String(decoding: candidate.integrity.manifestBytes, as: UTF8.self)
        guard let spliced = ManifestMemberSplice.setting(
            member,
            inObject: object,
            to: replacement,
            of: text
        ) else {
            return false
        }
        candidate.integrity.replaceManifest(bytes: Array(spliced.text.utf8))
        return true
    }

    // MARK: - Nonthrowing calls

    /// The finding one activation produced, or `nil` when it activated.
    ///
    /// Wrapped rather than rethrown: an error escaping the property body would report a
    /// passing run with every arm skipped.
    private static func activationFinding(
        _ activator: ModelBundleActivator,
        _ bundle: ModelBundleID,
        _ context: ReleaseContext
    ) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.activate(bundle, context: context)
            return nil
        } catch {
            return error
        }
    }

    private static func verifiedActiveFinding(
        _ activator: ModelBundleActivator,
        _ context: ReleaseContext
    ) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.verifiedActive(for: context)
            return nil
        } catch {
            return error
        }
    }

    private static func portFault(
        _ activator: ModelBundleActivator,
        _ context: ReleaseContext
    ) async -> AnalysisFault? {
        do {
            _ = try await activator.verifiedActiveBundle(for: context)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Fixture pieces

    /// A structurally valid manifest declaring `identity` and nothing else unusual.
    private static func manifest(
        declaring identity: ModelIdentity
    ) throws -> ModelBundleManifest {
        try ModelBundleManifest(
            schemaVersion: .v1,
            bundleID: Sample.bundle(),
            modelIdentity: identity,
            modelFormat: Sample.modelFormat(),
            inputContract: Sample.modelInput(),
            outputContract: Sample.modelOutput(),
            componentVersions: Sample.componentVersions(),
            artifacts: [
                ArtifactDigestRecord(
                    path: Sample.path("artifacts/model.mlmodelc"),
                    kind: .directoryTree,
                    byteCount: 8,
                    digest: Sample.digest()
                )
            ],
            compatibility: Sample.compatibility(),
            upstreamBoundaryMetadata: Sample.upstreamMetadata(),
            signingKey: Sample.signingKey()
        )
    }

    /// The schema refusal a manifest declaring `identity` must produce.
    private static func identityRefusal(for identity: ModelIdentity) -> ArtifactSchemaError {
        .fixedValueMismatch(
            field: "manifest.modelIdentity",
            expected: """
                \(ReferenceSolePixelModel.checkpointIdentifier) with weight digest \
                \(ReferenceSolePixelModel.weightDigestHexadecimal)
                """,
            found: """
                \(identity.checkpointIdentifier.rawValue) with weight digest \
                \(identity.requiredWeightDigest.hexadecimalString)
                """
        )
    }

    /// The value the Core ML adapter must produce before a prediction can run.
    private static func loadedModel(identity: ModelIdentity) -> BoundCoreMLModel? {
        BoundCoreMLModel(
            bundleID: Sample.bundle(),
            modelIdentity: identity,
            coreMLModelVersion: Sample.artifact("component.core-ml-model"),
            inputContract: Sample.modelInput(),
            outputContract: Sample.modelOutput(),
            model: LoadedModelToken(rawValue: 1)
        )
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
        _ witness: SolePixelModelWitness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordUnbuildableInput()
        Issue.record(message, sourceLocation: sourceLocation)
    }
}

// MARK: - Mutant values derived from a shape

extension ModelCatalogShape {
    /// How many identities outside the required one each case offers.
    fileprivate static let mutantIdentityCount = 3

    /// How many model formats outside the required one each case offers.
    fileprivate static let mutantFormatCount = 3

    /// Every identity a generated case offers that is not the sole permitted one: the
    /// checkpoint mutated, the digest mutated, and both mutated.
    ///
    /// All three, because Requirement 10.2 and Requirement 10.4 pin two independent halves
    /// of one identity and a check that compared only one half would accept a candidate
    /// with the right name and the wrong weights.
    fileprivate var mutantIdentities: [ModelIdentity] {
        [
            identity(
                checkpoint: mutantCheckpointIdentifier,
                digest: ReferenceSolePixelModel.weightDigestHexadecimal
            ),
            identity(
                checkpoint: ReferenceSolePixelModel.checkpointIdentifier,
                digest: mutantWeightDigestHexadecimal
            ),
            identity(
                checkpoint: mutantCheckpointIdentifier,
                digest: mutantWeightDigestHexadecimal
            ),
        ]
        .compactMap { $0 }
    }

    private func identity(checkpoint: String, digest: String) -> ModelIdentity? {
        guard let checkpointIdentifier = ModelCheckpointIdentifier(checkpoint),
              let weightDigest = DefAIkeDomain.SHA256Digest(hexadecimal: digest)
        else { return nil }
        return ModelIdentity(
            checkpointIdentifier: checkpointIdentifier,
            requiredWeightDigest: weightDigest
        )
    }

    /// The generated string one pinned leaf is spliced to.
    fileprivate func replacement(for field: PinnedModelField) -> String {
        switch field {
        case .checkpointIdentity: mutantCheckpointIdentifier
        case .requiredWeightDigest: mutantWeightDigestHexadecimal
        case .programKind: mutantProgramKind.rawValue
        case .computePrecision: mutantComputePrecision.rawValue
        case .minimumDeploymentTarget: mutantDeploymentTargetToken
        }
    }

    /// The schema refusal a manifest carrying that spliced leaf must produce.
    ///
    /// Spelled out per leaf rather than matched loosely, so a candidate refused for some
    /// other reason — a broken signature, an unparseable document, a size mismatch — fails
    /// the arm instead of passing it.
    fileprivate func schemaRefusal(for field: PinnedModelField) -> ArtifactSchemaError {
        switch field {
        case .checkpointIdentity:
            .fixedValueMismatch(
                field: "manifest.modelIdentity",
                expected: """
                    \(ReferenceSolePixelModel.checkpointIdentifier) with weight digest \
                    \(ReferenceSolePixelModel.weightDigestHexadecimal)
                    """,
                found: """
                    \(mutantCheckpointIdentifier) with weight digest \
                    \(ReferenceSolePixelModel.weightDigestHexadecimal)
                    """
            )
        case .requiredWeightDigest:
            .fixedValueMismatch(
                field: "manifest.modelIdentity",
                expected: """
                    \(ReferenceSolePixelModel.checkpointIdentifier) with weight digest \
                    \(ReferenceSolePixelModel.weightDigestHexadecimal)
                    """,
                found: """
                    \(ReferenceSolePixelModel.checkpointIdentifier) with weight digest \
                    \(mutantWeightDigestHexadecimal)
                    """
            )
        case .programKind:
            .fixedValueMismatch(
                field: "modelFormat.programKind",
                expected: ReferenceSolePixelModel.programKind,
                found: mutantProgramKind.rawValue
            )
        case .computePrecision:
            .fixedValueMismatch(
                field: "modelFormat.computePrecision",
                expected: ReferenceSolePixelModel.computePrecision,
                found: mutantComputePrecision.rawValue
            )
        case .minimumDeploymentTarget:
            .fixedValueMismatch(
                field: "modelFormat.minimumOS",
                expected: ReferenceSolePixelModel.minimumDeploymentTarget,
                found: mutantDeploymentTargetToken
            )
        }
    }

    /// Whether mutating `field` leaves the sole permitted pixel model, judged by the
    /// requirement-side model rather than by the code under test.
    fileprivate func leavesTheSolePermittedModel(_ field: PinnedModelField) -> Bool {
        !ReferenceSolePixelModel.isSolePermittedPixelModel(
            checkpointIdentifier: field == .checkpointIdentity
                ? mutantCheckpointIdentifier
                : ReferenceSolePixelModel.checkpointIdentifier,
            weightDigestHexadecimal: field == .requiredWeightDigest
                ? mutantWeightDigestHexadecimal
                : ReferenceSolePixelModel.weightDigestHexadecimal,
            programKind: field == .programKind
                ? mutantProgramKind.rawValue
                : ReferenceSolePixelModel.programKind,
            computePrecision: field == .computePrecision
                ? mutantComputePrecision.rawValue
                : ReferenceSolePixelModel.computePrecision,
            minimumDeploymentTarget: field == .minimumDeploymentTarget
                ? mutantDeploymentTargetToken
                : ReferenceSolePixelModel.minimumDeploymentTarget
        )
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
/// The produced sets are the substantive half. Each of the five pinned leaves must actually
/// have been refused by the real verification path, the exact compatible Lowq candidate must
/// actually have reached the weight measurement, the neutral splice must actually have
/// reached it too, and the load boundary must actually have accepted the required identity —
/// which is what turns "only the Lowq checkpoint binds" from a claim about unreached
/// branches into a claim about produced outcomes.
private final class SolePixelModelWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var constantChecks = 0
    private var schemaChecks = 0
    private var schemaIdentityRefusals = 0
    private var schemaFormatRefusals = 0
    private var loadBoundaryChecks = 0
    private var acceptedLoadIdentities = 0
    private var refusedLoadIdentities = 0
    private var catalogChecks = 0
    private var referenceTerminals = 0
    private var neutralControlTerminals = 0
    private var uncataloguedRefusals = 0
    private var pinnedFieldRefusals = 0
    private var unbuildableInputs = 0

    // Produced outcomes.
    private var refusedPinnedFields: Set<String> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var checkpointTokens: Set<String> = []
    private var weightDigests: Set<String> = []
    private var programKinds: Set<String> = []
    private var precisions: Set<String> = []
    private var deploymentTargets: Set<String> = []
    private var neutralComponentVersions: Set<String> = []
    private var weightBlobTokens: Set<String> = []
    private var catalogOrders: Set<Bool> = []
    private var strangerOrders: Set<Bool> = []

    func record(_ shape: ModelCatalogShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        checkpointTokens.insert(shape.mutantCheckpointIdentifier)
        weightDigests.insert(shape.mutantWeightDigestHexadecimal)
        programKinds.insert(shape.mutantProgramKind.rawValue)
        precisions.insert(shape.mutantComputePrecision.rawValue)
        deploymentTargets.insert(shape.mutantDeploymentTargetToken)
        neutralComponentVersions.insert(shape.neutralComponentVersionToken)
        weightBlobTokens.insert(shape.weightBlobToken)
        catalogOrders.insert(shape.catalogOrderReversed)
        strangerOrders.insert(shape.strangerRunsFirst)
    }

    func recordConstantCheck() {
        lock.lock()
        constantChecks += 1
        lock.unlock()
    }

    func recordSchemaCheck() {
        lock.lock()
        schemaChecks += 1
        lock.unlock()
    }

    func recordSchemaIdentityRefusal() {
        lock.lock()
        schemaIdentityRefusals += 1
        lock.unlock()
    }

    func recordSchemaFormatRefusal() {
        lock.lock()
        schemaFormatRefusals += 1
        lock.unlock()
    }

    func recordLoadBoundaryCheck() {
        lock.lock()
        loadBoundaryChecks += 1
        lock.unlock()
    }

    func recordAcceptedLoadIdentity() {
        lock.lock()
        acceptedLoadIdentities += 1
        lock.unlock()
    }

    func recordRefusedLoadIdentity() {
        lock.lock()
        refusedLoadIdentities += 1
        lock.unlock()
    }

    func recordCatalogCheck() {
        lock.lock()
        catalogChecks += 1
        lock.unlock()
    }

    func recordReferenceTerminal() {
        lock.lock()
        referenceTerminals += 1
        lock.unlock()
    }

    func recordNeutralControlTerminal() {
        lock.lock()
        neutralControlTerminals += 1
        lock.unlock()
    }

    func recordUncataloguedRefusal() {
        lock.lock()
        uncataloguedRefusals += 1
        lock.unlock()
    }

    func recordPinnedFieldRefusal(_ field: PinnedModelField) {
        lock.lock()
        pinnedFieldRefusals += 1
        refusedPinnedFields.insert(field.rawValue)
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

        // Every arm ran on every case. Compared against the case count rather than against
        // a floor: an arm that stopped being reached fails here even when the absolute
        // number still looks large.
        #expect(constantChecks == cases, "constant checks: \(constantChecks)")
        #expect(schemaChecks == cases, "schema checks: \(schemaChecks)")
        #expect(loadBoundaryChecks == cases, "load boundary checks: \(loadBoundaryChecks)")
        #expect(catalogChecks == cases, "catalog checks: \(catalogChecks)")

        // Three mutant identities and three mutant formats per case, and one accepted
        // identity beside the three refused ones.
        #expect(
            schemaIdentityRefusals == cases * ModelCatalogShape.mutantIdentityCount,
            "identities the manifest schema refused: \(schemaIdentityRefusals)"
        )
        #expect(
            schemaFormatRefusals == cases * ModelCatalogShape.mutantFormatCount,
            "formats the schema refused: \(schemaFormatRefusals)"
        )
        #expect(
            refusedLoadIdentities == cases * ModelCatalogShape.mutantIdentityCount,
            "identities the load boundary refused: \(refusedLoadIdentities)"
        )
        #expect(
            acceptedLoadIdentities == cases,
            "the load boundary accepted the required identity \(acceptedLoadIdentities) time(s)"
        )

        // The substantive half: the outcomes were produced, not merely offered.
        #expect(
            referenceTerminals == cases,
            """
            the exact compatible Lowq candidate reached the weight measurement \
            \(referenceTerminals) time(s)
            """
        )
        #expect(
            neutralControlTerminals == cases,
            """
            the neutrally spliced control reached the weight measurement \
            \(neutralControlTerminals) time(s); a lower number means splicing and re-signing \
            is itself refusing candidates
            """
        )
        #expect(
            uncataloguedRefusals == cases,
            "the uncatalogued candidate was refused \(uncataloguedRefusals) time(s)"
        )
        #expect(
            pinnedFieldRefusals == cases * PinnedModelField.allCases.count,
            "pinned-leaf mutants refused by the real path: \(pinnedFieldRefusals)"
        )
        #expect(
            refusedPinnedFields == Set(PinnedModelField.allCases.map(\.rawValue)),
            """
            pinned leaves never refused: \
            \(Set(PinnedModelField.allCases.map(\.rawValue)).subtracting(refusedPinnedFields).sorted())
            """
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(
            checkpointTokens.count >= 6,
            "generated checkpoint identifiers: \(checkpointTokens.count)"
        )
        #expect(weightDigests.count >= 50, "generated weight digests: \(weightDigests.count)")
        #expect(
            programKinds == ["neuralnetwork", "pipeline"],
            "generated program kinds: \(programKinds.sorted())"
        )
        #expect(precisions == ["float32"], "generated precisions: \(precisions.sorted())")
        #expect(
            deploymentTargets == ["16.0.0", "17.0.1", "17.1.0", "18.0.0", "26.0.0"],
            "generated deployment targets: \(deploymentTargets.sorted())"
        )
        #expect(
            neutralComponentVersions.count >= 50,
            "generated neutral component versions: \(neutralComponentVersions.count)"
        )
        #expect(
            weightBlobTokens.count >= 50,
            "generated weight-blob contents: \(weightBlobTokens.count)"
        )
        #expect(catalogOrders == [false, true], "only one catalog order was generated")
        #expect(strangerOrders == [false, true], "only one stranger order was generated")
    }
}
