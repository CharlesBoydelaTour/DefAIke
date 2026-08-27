import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

// Design Property 27: bundle activation and rollback are atomic.
//
// The design states it as: for any active verified bundle, local candidate, rollback
// candidate, and injected failure or interruption point, observers see either the entire
// prior compatible component tuple or the entire newly verified tuple, never a mixture;
// every failure leaves the prior active bundle unchanged, and rollback applies the same
// verification, self-test, and atomic-commit transitions without a network dependency.
//
// One generated fixture set per case, and eight injected boundaries walked on each of two
// paths. Every boundary in ``InjectedBoundary`` runs on every generated case, on both the
// new-candidate path and the rollback path, so the property is quantified over *where* the
// activation failed as well as over the generated inputs (Requirement 10.17).
//
// ## The three things every injected arm has to establish
//
// Atomicity assertions are absences, and an absence is satisfied for free by a run that
// never started. So each arm makes three claims, and the third is the one that keeps the
// other two honest:
//
//   1. **Observers see one complete tuple.** ``ObservedActivation`` is read *after* the
//      failure and carries the whole thing at once: every component version Requirement
//      10.13 enumerates, the model identity, the integrity projection with its complete
//      measured digest inventory, the compatibility matrix, the activation generation, and
//      the exact bytes of the durable pointer. It is compared as one value against the
//      admissible set — the complete old tuple or the complete new one — so a run that
//      advanced one field fails even though every field it advanced is individually
//      plausible (Requirements 10.12, 10.13).
//   2. **The prior bundle is unchanged.** The surviving bundle is re-verified through the
//      real integrity verifier after every failure and must produce the identical manifest
//      digest and artifact digest inventory, its tree is never read during an attempt on
//      the other bundle, and it is still bindable afterwards (Requirements 10.12, 10.16).
//   3. **The failure landed exactly at the injected boundary and no further.**
//      ``ReferenceAtomicActivationModel`` states, from the design's fixed step order and
//      from Requirement 10.12 rather than from the code, the exact ordered list of durable
//      store operations each boundary is expected to reach, how many receipts it may have
//      written, and how far into the self-test run it may have got. Without this table an
//      injection that silently degenerated into "failed before anything happened" would
//      satisfy every atomicity assertion above while testing nothing.
//
// ## The positive control
//
// "Nothing changed" is worthless without a path that provably does change things, so every
// case also runs one un-injected activation per path through the same real types, and
// asserts that the observable state advanced to the complete new tuple, that the durable
// generation advanced by exactly one, and that the old and new tuples are distinct. The
// admissible set is checked to have exactly two members, so "observers saw the old tuple"
// is never satisfied because the old and new tuples were the same value.
//
// ## The gitignored weight blob, and what that costs
//
// Requirement 10.4 pins the weight-blob digest to one SHA-256 value, and the approved 43 MB
// blob is not in this repository. Fabricating that digest would disable the one check that
// pins model identity to bytes, so nothing here does. The consequence is structural and
// worth stating plainly:
//
//   * **Steps 1 through 3 are the real verifiers over the real fixture bytes.** Both
//     verification boundaries below are injected and observed through
//     ``ModelBundleActivator/activateLocalCandidate(_:context:)`` and
//     ``ModelBundleActivator/rollback(to:context:)`` — the actual port members.
//   * **The whole path cannot reach step 7 for a synthetic candidate.** It terminates at
//     ``ModelBundleVerificationError/modelWeightDigestMismatch(_:)``, which is this
//     project's "everything before it passed" signal. So the four step-7 boundaries are
//     driven through ``ModelBundleActivator/commit(_:context:)`` — the real commit, reached
//     with a ``SelfTestedBundleCandidate`` produced by a real ``ReleaseSelfTestRunner`` pass
//     over the real fixture bytes, whose ``CompatibleBundleCandidate`` is built through the
//     module-internal initializer with the required weight digest supplied as the *measured*
//     one. That construction is the only step not performed by production code, and it is
//     the same one `ActivationAndRollbackTests` and `ActivationDoubles` already use.
//   * **An observable successful activation is therefore reachable, but only through
//     `commit`.** It is a genuine commit: a real receipt, a real durable pointer, a real
//     `BoundModelBundle`. What is *not* reachable is a successful activation through
//     `activateLocalCandidate` or `rollback`, so the entry-point identity for Requirement
//     10.17 is established at the deepest boundary the whole path can reach rather than at a
//     successful one. See ``AtomicActivationAndRollbackPropertyTests``'s entry-point arm.
//
// Whether the real released blob hashes to the required value is an integration question
// against the immutable artifact and belongs to task 6.11.
//
// ## Nothing here is release evidence
//
// Every policy, key, digest, identifier, fixture, byte, expectation, and application build
// below is **synthetic** and exists so that verifiers which take approved inputs can be
// called at all. No signature algorithm ran, no compiled model was loaded, no prediction was
// made, and no fixture parity was measured. No approved fixture artifact, release fixture
// suite, device validation plan, evidence fusion rule, or offline trust store exists in this
// repository, and none is fabricated here.
//
// ## No model-update channel is observable, and how that is stated
//
// There is no runtime network-observation seam in this module, so this file does not invent
// one. What it does assert is the seam vocabulary: across every arm, the durable store was
// asked only for operations drawn from ``ReferenceAtomicActivationModel/storeVocabulary``,
// and the content store was asked only to enumerate or read one of the two locally installed
// bundle identifiers. Neither vocabulary contains a member that could name, discover, fetch,
// or download anything (Requirements 10.19, 10.21). The source-text scan that pins the same
// absence across the module's files already lives in `ActivationAndRollbackTests` and is not
// duplicated.
//
// ## What this file deliberately does not assert
//
//   * Whether a manifest's artifact inventory is complete and mutation-sensitive. That is
//     Property 26's statement (task 6.9). The integrity boundary below mutates exactly one
//     declared artifact's bytes, and asserts only what atomicity needs: that the refusal
//     happened before anything durable was written.
//   * That a session keeps its bound snapshot across a later activation. That is Property
//     13's (task 6.7), already covered.
//   * That only the Lowq checkpoint can bind. That is Property 2's (task 6.6).
//   * Real signature vectors, real Core ML loads, or the released bundle. Those are task
//     6.11's integration tests.
//
// ## Why no arm throws
//
// `propertyCheck` runs its body under `try?`, so an error escaping the body reports a
// passing run in milliseconds with every arm skipped. Nothing below rethrows: every throwing
// assembler, verifier, runner, activator, and store call is wrapped into a value or reported
// through `Issue.record`, and ``AtomicActivationWitness`` counts the cases and every arm
// *outside* the body, where an issue is not suppressed. Arm counters are compared against the
// case count rather than against a floor, and ``AtomicActivationWitness/recordCompletedBody()``
// is the last thing the body does, so a case that stopped early is countable.

extension Tag {
    /// Design Property 27.
    ///
    /// Declared here rather than in a shared tag namespace: each design property gets one
    /// dedicated file, and a shared namespace would be a merge point between property files
    /// written independently of each other.
    @Tag static var property27AtomicActivationAndRollback: Self
}

@Suite(
    "Property 27: bundle activation and rollback are atomic",
    .tags(.property27AtomicActivationAndRollback)
)
struct AtomicActivationAndRollbackPropertyTests {
    /// Runs at the library default of 100 generated cases, which is the minimum the design
    /// requires; `PropertyToolchainWiringTests` pins that default. Every generator is
    /// composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 10.12, 10.13, 10.16, 10.17**
    @Test("Every injected failure leaves observers the whole old tuple, on both paths")
    func activationAndRollbackAreAtomicUnderEveryInjectedFailure() async {
        let witness = AtomicActivationWitness()

        await propertyCheck(input: AtomicityShape.generator) { shape in
            witness.record(shape)

            for path in shape.pathOrder {
                await AtomicityScenario.run(shape, path: path, witness: witness)
            }
            await AtomicityScenario.checkRollbackTakesTheIdenticalPath(shape, witness: witness)

            witness.recordCompletedBody()
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The boundaries a failure is injected at

/// Where one activation attempt is made to fail.
///
/// Named after the design's verification order, so an arm states the boundary it means
/// rather than the mechanism it used to get there. The six the task names are all present;
/// two of them are split because the design separates them and an interruption between the
/// halves has a different observable consequence:
///
///   * *verification* is split into the integrity half (a declared artifact's bytes do not
///     digest to the signed value) and the compatibility half (the running build is not one
///     the bundle declares);
///   * *pointer-write* is split into staging the new pointer and atomically replacing the
///     published one, because the design writes the pointer to a temporary location,
///     synchronizes it, and then renames it, and only the last of those three is a
///     publication.
private enum InjectedBoundary: String, Hashable, Sendable, CaseIterable {
    /// Step 3. One declared artifact's bytes changed, at the same length, so only a digest
    /// can catch it.
    case integrityVerification = "integrity-verification"

    /// Step 5. The running application build is not one the bundle's compatibility matrix
    /// declares.
    case compatibilityVerification = "compatibility-verification"

    /// Step 6, load boundary. The candidate's compiled model would not load, so its
    /// self-tests could not run.
    case candidateModelLoad = "candidate-model-load"

    /// Step 6, comparison boundary. One declared expected result disagreed with what the run
    /// produced.
    case releaseSelfTest = "release-self-test"

    /// Step 7. The immutable receipt could not be persisted.
    case receiptPersistence = "receipt-persistence"

    /// Step 7. The new pointer could not be written to its staging location.
    case pointerStaging = "pointer-staging"

    /// Step 7. Staged pointer bytes did not reach stable storage.
    case stateSynchronization = "state-synchronization"

    /// Step 7. The atomic replacement of the published pointer did not complete — the
    /// interruption the whole ordering exists for.
    case pointerReplacement = "pointer-replacement"

    /// Whether this boundary is reachable through the real port entry points.
    ///
    /// The two verification boundaries are; everything at or after step 6 is not, because a
    /// synthetic candidate stops at the pinned weight digest first. See the file header.
    var isReachableThroughThePortEntryPoint: Bool {
        switch self {
        case .integrityVerification, .compatibilityVerification: true
        default: false
        }
    }
}

/// Which of the two paths Requirement 10.17 makes identical is being exercised.
private enum ActivationPath: String, Hashable, Sendable, CaseIterable {
    /// A locally installed candidate that has never been active is activated while another
    /// bundle is active.
    case newCandidate = "new-candidate"

    /// A retained prior bundle is returned to while a newer one is active.
    ///
    /// "Prior" does not imply trusted: the bundle being rolled back to runs the identical
    /// verification, self-test, and commit path a new candidate does.
    case rollback = "rollback"
}

// MARK: - The reference model

/// How far each injected boundary is expected to get, written from the requirements and the
/// design's fixed step order rather than from the code under test.
///
/// The ordering is the requirement. Requirement 10.12 puts every verification and self-test
/// refusal *before* anything durable is written. The design fixes step 7 as "the receipt is
/// persisted before the pointer that names it", and "the active pointer is written to a
/// temporary file, synchronized, and atomically renamed" — three separable operations, so an
/// interruption between any two of them has its own expected reach. Staged state that will
/// not be published is dropped on every exit path.
///
/// Reading the expected reach off this table rather than off the activator is what turns "the
/// activation stopped where this arm meant it to" into a comparison against the requirement.
private enum ReferenceAtomicActivationModel {
    // The durable operations the design's step 7 performs, in the order it fixes them.
    static let readsTheGeneration = "activePointer"
    static let writesTheReceipt = "persistReceipt"
    static let stagesThePointer = "stage"
    static let synchronizesStagedState = "synchronize"
    static let replacesThePointer = "publish"
    static let dropsStagedState = "discard"

    /// Every durable operation an activation may perform, plus the two read-only lookups the
    /// seam exposes.
    ///
    /// A closed vocabulary is how "no model-update request" is observable here: none of these
    /// names can fetch, discover, download, or resolve anything.
    static let storeVocabulary: Set<String> = [
        readsTheGeneration,
        "receipt",
        writesTheReceipt,
        stagesThePointer,
        synchronizesStagedState,
        replacesThePointer,
        dropsStagedState,
    ]

    /// The complete step 7 an un-injected activation performs.
    static let completeCommit = [
        readsTheGeneration,
        writesTheReceipt,
        stagesThePointer,
        synchronizesStagedState,
        replacesThePointer,
    ]

    /// What one attempt is expected to have reached.
    struct Reach: Hashable, Sendable, CustomStringConvertible {
        /// Durable store operations, in order. Empty means the store was never asked
        /// anything, which is what Requirement 10.12 requires of every pre-activation
        /// refusal.
        let durableStoreOperations: [String]

        /// Receipts that reached storage. At most one: an attempt writes one record or none.
        let receiptsPersisted: Int

        /// Successful loads of the candidate's compiled model.
        let candidateModelLoads: Int

        /// Fixtures the run reached, so a comparison failure is distinguishable from a load
        /// failure by more than its finding.
        let fixtureRunsReached: Int

        /// Unloads of the candidate. A rejected candidate must not stay loaded, so a run that
        /// loaded one and then failed still unloads it.
        let candidateUnloads: Int

        var description: String {
            """
            store \(durableStoreOperations), receipts \(receiptsPersisted), \
            loads \(candidateModelLoads), runs \(fixtureRunsReached), \
            unloads \(candidateUnloads)
            """
        }
    }

    /// The reach one injected boundary is expected to produce.
    ///
    /// - Parameters:
    ///   - boundary: where the failure was injected.
    ///   - selfTestCaseCount: how many cases the candidate's specification declares.
    ///   - failingCaseIndex: which case the self-test comparison boundary makes disagree.
    static func reach(
        of boundary: InjectedBoundary,
        selfTestCaseCount: Int,
        failingCaseIndex: Int
    ) -> Reach {
        switch boundary {
        case .integrityVerification, .compatibilityVerification:
            // Refused while the bytes and the compatibility metadata are checked. Nothing is
            // loaded, nothing is run, and the record store is never asked anything, so there
            // is nothing for a later launch to find (Requirement 10.12).
            return Reach(
                durableStoreOperations: [],
                receiptsPersisted: 0,
                candidateModelLoads: 0,
                fixtureRunsReached: 0,
                candidateUnloads: 0
            )
        case .candidateModelLoad:
            // The load itself refused, so no model is resident and no fixture ran. Nothing
            // durable was touched.
            return Reach(
                durableStoreOperations: [],
                receiptsPersisted: 0,
                candidateModelLoads: 0,
                fixtureRunsReached: 0,
                candidateUnloads: 0
            )
        case .releaseSelfTest:
            // The model loaded and the run reached the disagreeing case. Cases after it never
            // ran, and the candidate was unloaded rather than left resident. Still nothing
            // durable: a self-test failure never becomes a receipt (Requirement 10.12).
            return Reach(
                durableStoreOperations: [],
                receiptsPersisted: 0,
                candidateModelLoads: 1,
                fixtureRunsReached: failingCaseIndex + 1,
                candidateUnloads: 1
            )
        case .receiptPersistence:
            // The generation was read and the write was attempted. It did not reach storage,
            // so no record exists and no pointer was staged.
            return Reach(
                durableStoreOperations: [readsTheGeneration, writesTheReceipt],
                receiptsPersisted: 0,
                candidateModelLoads: 1,
                fixtureRunsReached: selfTestCaseCount,
                candidateUnloads: 1
            )
        case .pointerStaging:
            // The receipt is durable — a record that a verification run happened, which is
            // not an activation — and staging refused. There is nothing staged to drop.
            return Reach(
                durableStoreOperations: [
                    readsTheGeneration, writesTheReceipt, stagesThePointer,
                ],
                receiptsPersisted: 1,
                candidateModelLoads: 1,
                fixtureRunsReached: selfTestCaseCount,
                candidateUnloads: 1
            )
        case .stateSynchronization:
            // Staged but not durable, so the staged state is dropped rather than published.
            return Reach(
                durableStoreOperations: [
                    readsTheGeneration, writesTheReceipt, stagesThePointer,
                    synchronizesStagedState, dropsStagedState,
                ],
                receiptsPersisted: 1,
                candidateModelLoads: 1,
                fixtureRunsReached: selfTestCaseCount,
                candidateUnloads: 1
            )
        case .pointerReplacement:
            // Everything short of the rename completed and the rename did not. The published
            // pointer never moved and the staged state was dropped (Requirement 10.12).
            return Reach(
                durableStoreOperations: completeCommit + [dropsStagedState],
                receiptsPersisted: 1,
                candidateModelLoads: 1,
                fixtureRunsReached: selfTestCaseCount,
                candidateUnloads: 1
            )
        }
    }

    /// The reach an un-injected activation is expected to produce.
    ///
    /// The positive control: one receipt, the whole fixed step 7, nothing dropped.
    static func controlReach(selfTestCaseCount: Int) -> Reach {
        Reach(
            durableStoreOperations: completeCommit,
            receiptsPersisted: 1,
            candidateModelLoads: 1,
            fixtureRunsReached: selfTestCaseCount,
            candidateUnloads: 1
        )
    }
}

// MARK: - Generated shape

/// One generated fixture set.
///
/// Every field is a bounded integer or a flag, and each derived value is read off the shape
/// by modulus, so a family is exercised across all of its members over 100 cases instead of
/// collapsing onto one.
private struct AtomicityShape: Sendable, CustomStringConvertible {
    /// Drives the generated artifact contents, component tokens, and foreign build, so a
    /// case's values vary together and a failing case names one seed.
    let seed: Int

    /// Rotates the order the boundaries are walked in.
    ///
    /// The activator holds the active pointer and an activation generation, so exercising
    /// every rotation is what shows that no boundary's outcome depends on which boundary was
    /// attempted before it.
    let boundaryRotationIndex: Int

    /// Which declared artifact the integrity boundary mutates a byte of.
    let mutationTargetIndex: Int

    /// Which byte inside that artifact is changed.
    let mutationByteIndex: Int

    /// Whether the candidate declares one self-test case or two.
    let selfTestCountIndex: Int

    /// Which label the self-test boundary makes the run report instead of the declared one.
    let wrongLabelIndex: Int

    /// Whether the rollback path runs before the new-candidate path.
    let rollbackPathRunsFirst: Bool

    /// Whether the un-injected positive control runs before the injected arms.
    let controlRunsFirst: Bool

    // MARK: Derived fixtures

    /// A canonical token that varies per case. Pinned positive so no generated identifier
    /// can collapse onto a placeholder.
    var token: String { "\(1 + seed % 999)" }

    /// How many self-test cases the candidate declares.
    var selfTestCaseCount: Int { 1 + selfTestCountIndex % 2 }

    /// Which declared case the self-test comparison boundary makes disagree.
    var failingCaseIndex: Int { seed % selfTestCaseCount }

    /// The generated self-test cases.
    ///
    /// One expectation each, kept as the declared Non Positive Pixel Label, because the
    /// fixture catalogue entry declares that same expectation: changing the *declared*
    /// expectation would make the specification and the catalogue disagree, which is a
    /// Property 26 subject. What varies here is the fixture bytes and, for the self-test
    /// boundary, the label the run reports.
    var selfTests: [SampleSelfTest] {
        (0..<selfTestCaseCount).map { index in
            let suffix = index == 0 ? "a" : "b"
            return SampleSelfTest(
                caseID: "self-test.p27-\(suffix)",
                fixtureID: "fixture.p27-\(suffix)",
                suiteRelativePath: "p27-\(suffix).jpg",
                bytes: Array("fixture-p27-\(suffix)-\(token)".utf8),
                expectations: [.pixelLabel(.noStrongSignalDetected)]
            )
        }
    }

    /// The declared pixel label every generated case expects.
    var declaredLabel: PixelLabelKey { .noStrongSignalDetected }

    /// A label that is not the declared one.
    ///
    /// The table is the whole complement of the declared label rather than a sample of it,
    /// so adding a fourth label has to extend it rather than silently go ungenerated.
    var reportedWrongLabel: PixelLabelKey {
        let table = PixelLabelKey.allCases.filter { $0 != declaredLabel }
        return table[wrongLabelIndex % table.count]
    }

    /// Same-length replacement content for the compiled model's data file.
    ///
    /// Held at the assembler's own placeholder length, because the declared tree record is
    /// derived from the tree after this replacement while the enumeration still reports the
    /// original size; a different length would make the candidate fail on a size mismatch
    /// instead of on its digest.
    var compiledModelDataBytes: [UInt8] {
        Self.sameLengthFill(prefix: "core-ml-", totalCount: 12, seed: seed)
    }

    /// Same-length replacement content for the weight blob.
    var weightBlobBytes: [UInt8] {
        Self.sameLengthFill(prefix: "weight-", totalCount: 11, seed: seed &* 31)
    }

    /// An application build the generated bundles do not declare compatibility with.
    var foreignAppBuild: AppBuildID { Sample.appBuild("build.p27-foreign-\(token)") }

    /// The running context the compatibility boundary injects.
    var foreignContext: ReleaseContext { Sample.releaseContext(appBuild: foreignAppBuild) }

    /// The boundaries this case walks, in generated order.
    var boundaryOrder: [InjectedBoundary] {
        let all = InjectedBoundary.allCases
        let offset = boundaryRotationIndex % all.count
        return Array(all[offset...] + all[..<offset])
    }

    /// The paths this case walks, in generated order.
    var pathOrder: [ActivationPath] {
        rollbackPathRunsFirst
            ? [.rollback, .newCandidate]
            : [.newCandidate, .rollback]
    }

    // MARK: Description

    var description: String {
        """
        seed \(seed), self-tests \(selfTestCaseCount), failing case \(failingCaseIndex), \
        wrong label \(reportedWrongLabel.rawValue), \
        mutation target \(mutationTargetIndex % IntegrityMutationTarget.allCases.count), \
        mutation byte \(mutationByteIndex), \
        foreign build \(foreignAppBuild.rawValue), \
        boundary order \(boundaryOrder.map(\.rawValue)), \
        rollback first \(rollbackPathRunsFirst), control first \(controlRunsFirst)
        """
    }

    // MARK: Generator

    static var generator: Generator<AtomicityShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            index,
            index,
            index,
            index,
            index,
            Gen.bool,
            Gen.bool
        )
        .map { raw in
            AtomicityShape(
                seed: raw.0,
                boundaryRotationIndex: raw.1,
                mutationTargetIndex: raw.2,
                mutationByteIndex: raw.3,
                selfTestCountIndex: raw.4,
                wrongLabelIndex: raw.5,
                rollbackPathRunsFirst: raw.6,
                controlRunsFirst: raw.7
            )
        }
        .eraseToAny()
    }

    /// A selector index.
    ///
    /// The range is a multiple of every modulus it is reduced by (2, 3, 8), so each table
    /// entry is drawn with equal probability rather than with a modulus bias.
    private static var index: Generator<Int, AnySequence<Any>> {
        Gen.int(in: 0...959).eraseToAny()
    }

    /// `totalCount` bytes beginning with `prefix`, filled with seed-derived hexadecimal.
    private static func sameLengthFill(
        prefix: String,
        totalCount: Int,
        seed: Int
    ) -> [UInt8] {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = Array(prefix.utf8)
        var value = UInt64(bitPattern: Int64(seed)) &* 2_654_435_761 &+ 1
        while bytes.count < totalCount {
            bytes.append(digits[Int(value & 0xF)])
            value = (value >> 4) &+ 1
        }
        return Array(bytes.prefix(totalCount))
    }
}

// MARK: - What the integrity boundary mutates

/// One declared artifact whose bytes the integrity boundary changes.
///
/// Three targets, one per shape of declared record the bundle carries: a member of a declared
/// directory tree, a declared file, and a member of a second declared directory tree. Each
/// produces a refusal naming the *declared* artifact whose digest covers the changed bytes,
/// which is what distinguishes "the digest was measured" from "the file was noticed".
private enum IntegrityMutationTarget: String, Hashable, Sendable, CaseIterable {
    case compiledModelMember = "compiled-model-member"
    case selfTestSpecificationFile = "self-test-specification-file"
    case fixtureAssetMember = "fixture-asset-member"

    /// The path whose bytes change.
    func mutatedPath(firstFixturePath: String) -> String {
        switch self {
        case .compiledModelMember:
            "\(CompatibleBundleAssembler.modelTreePath)/coremldata.bin"
        case .selfTestSpecificationFile:
            CompatibleBundleAssembler.selfTestsPath
        case .fixtureAssetMember:
            "\(CompatibleBundleAssembler.fixtureRootPath)/\(firstFixturePath)"
        }
    }

    /// The declared artifact whose digest covers those bytes, and which the finding names.
    var declaredArtifactPath: String {
        switch self {
        case .compiledModelMember: CompatibleBundleAssembler.modelTreePath
        case .selfTestSpecificationFile: CompatibleBundleAssembler.selfTestsPath
        case .fixtureAssetMember: CompatibleBundleAssembler.fixtureRootPath
        }
    }
}

// MARK: - What an observer sees

/// The complete component tuple one activation replaces, as an observer reads it.
///
/// Every member Requirement 10.13 enumerates is present: the Core ML model, Preprocessing
/// Contract, and Calibration Policy versions, the model identity, the scope metadata, the
/// integrity metadata with its complete measured digest inventory, the compatibility
/// metadata, the Approved Verdict Copy compatibility identifier, and the release self-test
/// specification — plus the generation that distinguishes two activations of the same bundle.
///
/// Flattened to comparable scalars on purpose. The oracle for "never a mixture" is whole-value
/// equality against an admissible set of exactly two tuples, and a mixture is precisely a
/// value that equals neither while every field individually looks plausible.
private struct ActiveTuple: Hashable, Sendable, CustomStringConvertible {
    let bundleID: String
    let checkpointIdentifier: String
    let requiredWeightDigest: String
    let coreMLModel: String
    let preprocessingContract: String
    let calibrationPolicy: String
    let evidenceScope: String
    let verdictCopyCompatibility: String
    let selfTestSpecification: String
    let integrityStatus: String
    let activationReceiptID: String
    let verificationPolicyID: String
    let verifiedManifestDigest: String
    let verifiedArtifactDigests: [String]
    let compatibleAppBuilds: [String]
    let requiredCapabilities: [String]
    let minimumOS: String
    let activationGeneration: Int

    init(_ bundle: BoundModelBundle) {
        bundleID = bundle.bundleID.rawValue
        checkpointIdentifier = bundle.modelIdentity.checkpointIdentifier.rawValue
        requiredWeightDigest = bundle.modelIdentity.requiredWeightDigest.hexadecimalString
        coreMLModel = bundle.componentVersions.coreMLModel.rawValue
        preprocessingContract = bundle.componentVersions.preprocessingContract.rawValue
        calibrationPolicy = bundle.componentVersions.calibrationPolicy.rawValue
        evidenceScope = bundle.componentVersions.evidenceScope.rawValue
        verdictCopyCompatibility = bundle.componentVersions.verdictCopyCompatibility.rawValue
        selfTestSpecification = bundle.componentVersions.selfTestSpecification.rawValue
        integrityStatus = bundle.integrity.status.rawValue
        activationReceiptID = bundle.integrity.activationReceiptID.rawValue
        verificationPolicyID = bundle.integrity.verificationPolicyID.rawValue
        verifiedManifestDigest = bundle.integrity.verifiedManifestDigest.hexadecimalString
        verifiedArtifactDigests = bundle.integrity.verifiedArtifactDigests
            .map {
                "\($0.path.rawValue)|\($0.kind.rawValue)|\($0.byteCount)|"
                    + $0.digest.hexadecimalString
            }
            .sorted()
        compatibleAppBuilds = bundle.manifest.compatibility.compatibleAppBuilds
            .map(\.rawValue).sorted()
        requiredCapabilities = bundle.manifest.compatibility.requiredCapabilities
            .map(\.rawValue).sorted()
        minimumOS = bundle.manifest.compatibility.minimumOS.description
        activationGeneration = bundle.activationGeneration.value
    }

    /// How many separately named members this tuple carries.
    ///
    /// Asserted against rather than trusted, so a tuple that quietly stopped carrying one of
    /// Requirement 10.13's members fails instead of shrinking the oracle.
    static let memberCount = 18

    var memberCount: Int {
        [
            bundleID, checkpointIdentifier, requiredWeightDigest, coreMLModel,
            preprocessingContract, calibrationPolicy, evidenceScope, verdictCopyCompatibility,
            selfTestSpecification, integrityStatus, activationReceiptID, verificationPolicyID,
            verifiedManifestDigest, minimumOS,
        ].count
            + [verifiedArtifactDigests, compatibleAppBuilds, requiredCapabilities].count
            + 1
    }

    var description: String { "\(bundleID)@\(activationGeneration) [\(activationReceiptID)]" }
}

/// Everything an observer of the Model Bundle Manager can read at one instant.
///
/// Both halves at once, deliberately. The in-memory tuple alone would not catch a durable
/// pointer that advanced without it, and the durable pointer alone would not catch the
/// reverse. The pointer is carried as its exact bytes as well as its decoded fields, so a
/// store that rewrote it with different bytes that happen to decode equally is still caught.
private struct ObservedActivation: Hashable, Sendable, CustomStringConvertible {
    let active: ActiveTuple?
    let publishedPointerBytes: [UInt8]?
    let publishedBundleID: String?
    let publishedReceiptID: String?
    let publishedGeneration: Int?

    /// Whether the two halves describe the same activation.
    ///
    /// The other face of "never a mixture": an in-memory tuple that disagreed with the
    /// durable pointer about which bundle, which receipt, or which generation is active would
    /// be a mixture of two activations even though each half is internally complete.
    var isCoherent: Bool {
        guard let active else {
            return publishedPointerBytes == nil
                && publishedBundleID == nil
                && publishedReceiptID == nil
                && publishedGeneration == nil
        }
        return active.bundleID == publishedBundleID
            && active.activationReceiptID == publishedReceiptID
            && active.activationGeneration == publishedGeneration
    }

    var description: String {
        guard let active else { return "nothing active" }
        return "\(active), pointer \(publishedBundleID ?? "nil")@\(publishedGeneration ?? -1)"
    }
}

/// What one bundle's verified bytes measured to.
///
/// The observable form of "the prior bundle is unchanged". Byte-level immutability is
/// structural — ``ModelBundleContentReading`` has no member that writes anything — so what
/// makes it a measurement rather than a restatement is re-running the real integrity verifier
/// after every failure and comparing the digests it produces to the ones it produced before.
private struct MeasuredBundleBytes: Hashable, Sendable {
    let manifestDigest: String
    let artifactDigests: [String]
    let treeEntries: [String]
    let fileDigests: [String]

    init(tree: VerifiedBundleArtifactTree, content: FakeBundleTree) {
        manifestDigest = tree.manifestDigest.hexadecimalString
        artifactDigests = tree.verifiedArtifacts
            .map { "\($0.path.rawValue)|\($0.digest.hexadecimalString)" }
            .sorted()
        treeEntries = content.treeEntries.map { "\($0.rawPath)|\($0.kind)" }.sorted()
        fileDigests = content.fileBytes
            .map { "\($0.key)|" + StreamingSHA256.digest(of: $0.value).hexadecimalString }
            .sorted()
    }
}

// MARK: - Owned injection seams

/// Records every content operation one run performed, in order.
///
/// A locked class rather than an actor, so the ledger can be read synchronously from an arm
/// without another suspension point in the middle of an assertion.
private final class ContentLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func recordEnumeration(of bundle: ModelBundleID) {
        lock.lock()
        entries.append("enumerate:\(bundle.rawValue)")
        lock.unlock()
    }

    func recordRead(of path: CanonicalRelativePath, in bundle: ModelBundleID) {
        lock.lock()
        entries.append("read:\(bundle.rawValue):\(path.rawValue)")
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Operations recorded since `mark`.
    func delta(since mark: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard mark <= entries.count else { return [] }
        return Array(entries[mark...])
    }
}

/// One scripted, reversible byte substitution inside a locally installed bundle.
///
/// A read-time substitution rather than an edit of the fixture, and never an edit of
/// production source: the artifact tree the store enumerates is untouched, so the substituted
/// bytes keep the declared length and only a digest can catch them. Reversible because the
/// arms run sequentially against one activator, and a corruption left in place would change
/// what every later arm measures.
private final class ByteSubstitutionSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var substitutions: [String: [UInt8]] = [:]

    private static func key(_ bundle: ModelBundleID, _ path: String) -> String {
        "\(bundle.rawValue)\u{1}\(path)"
    }

    func substitute(_ bytes: [UInt8], at path: String, in bundle: ModelBundleID) {
        lock.lock()
        substitutions[Self.key(bundle, path)] = bytes
        lock.unlock()
    }

    func clear() {
        lock.lock()
        substitutions.removeAll()
        lock.unlock()
    }

    func bytes(at path: CanonicalRelativePath, in bundle: ModelBundleID) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return substitutions[Self.key(bundle, path.rawValue)]
    }
}

/// Serves two locally installed candidate trees from one content seam, records every
/// operation, and honours one reversible byte substitution.
///
/// A wrapper rather than a double: the trees, their enumerations, and their bytes are the real
/// fixture ones, and the only things added are a ledger and one scripted substitution. It has
/// no write member at all, which is the seam's own guarantee rather than this wrapper's
/// choice.
private struct InjectableContentStore: ModelBundleContentReading {
    let trees: [String: FakeBundleTree]
    let ledger: ContentLedger
    let substitution: ByteSubstitutionSwitch

    func entries(in bundle: ModelBundleID) throws(BundleContentFault) -> [BundleTreeEntry] {
        guard let tree = trees[bundle.rawValue] else { throw .storeUnavailable }
        ledger.recordEnumeration(of: bundle)
        return try tree.entries(in: bundle)
    }

    func readFile(
        at path: CanonicalRelativePath,
        in bundle: ModelBundleID,
        chunkByteCount: Int,
        into sink: (ArraySlice<UInt8>) -> BundleReadDisposition
    ) throws(BundleContentFault) {
        guard let tree = trees[bundle.rawValue] else { throw .storeUnavailable }
        ledger.recordRead(of: path, in: bundle)
        guard let replacement = substitution.bytes(at: path, in: bundle) else {
            try tree.readFile(
                at: path,
                in: bundle,
                chunkByteCount: chunkByteCount,
                into: sink
            )
            return
        }
        guard chunkByteCount > 0 else { return }
        var offset = 0
        while offset < replacement.count {
            let end = min(offset + chunkByteCount, replacement.count)
            if sink(replacement[offset..<end]) == .stop { return }
            offset = end
        }
    }
}

// MARK: - One generated harness

/// Two assembled candidates, one approved configuration listing both, the real activator over
/// them, and the seams this file injects through.
///
/// Assembled per case so the fixture bytes vary; the approved configuration, evidence scope,
/// layout, verification policy, signature stand-in, and running context all come from one of
/// the two candidates, so both bundles are judged by one build's approved inputs rather than
/// by each candidate's own.
private struct AtomicityHarness {
    let priorID: ModelBundleID
    let candidateID: ModelBundleID
    let assembledPrior: CompatibleCandidate
    let assembledCandidate: CompatibleCandidate
    let content: InjectableContentStore
    let ledger: ContentLedger
    let substitution: ByteSubstitutionSwitch
    let store: FakeActivationRecordStore
    let clock: SteppingClock
    let activator: ModelBundleActivator
    let context: ReleaseContext
    let selfTests: [SampleSelfTest]

    /// The executor the activator's *own* self-test runner would use.
    ///
    /// Injected rather than left to the builder's default so that "the whole path never
    /// reached step 6" is a measurement on this object rather than an inference from the
    /// finding. Nothing else in this file drives it: the step-6 and step-7 arms build their
    /// own runner with their own executor, and ``activateForReal(_:)`` does too, so any load
    /// recorded here came from ``ModelBundleActivator/activate(_:context:)``.
    let wholePathExecutor: FakeSelfTestExecutor

    static let priorToken = "bundle.p27-prior"
    static let candidateToken = "bundle.p27-candidate"

    /// Assembles one harness, or `nil` when a described fixture was not buildable.
    static func built(_ shape: AtomicityShape) -> AtomicityHarness? {
        let prior = Sample.bundle(priorToken)
        let candidate = Sample.bundle(candidateToken)
        let tests = shape.selfTests
        let overrides: (inout FakeBundleTree) -> Void = { tree in
            // Same-length replacements, so the declared records the assembler derives after
            // this closure still agree with what the enumeration reports.
            tree.overwriteContent(
                "\(CompatibleBundleAssembler.modelTreePath)/coremldata.bin",
                bytes: shape.compiledModelDataBytes
            )
            tree.overwriteContent(
                CompatibleBundleAssembler.weightBlobPath,
                bytes: shape.weightBlobBytes
            )
        }
        guard let assembledPrior = try? CompatibleBundleAssembler.standard(
            bundleID: prior,
            selfTests: tests,
            bundleCatalog: [prior, candidate],
            treeOverrides: overrides
        ),
            let assembledCandidate = try? CompatibleBundleAssembler.standard(
                bundleID: candidate,
                selfTests: tests,
                bundleCatalog: [prior, candidate],
                treeOverrides: overrides
            )
        else { return nil }

        let ledger = ContentLedger()
        let substitution = ByteSubstitutionSwitch()
        let content = InjectableContentStore(
            trees: [
                prior.rawValue: assembledPrior.integrity.tree,
                candidate.rawValue: assembledCandidate.integrity.tree,
            ],
            ledger: ledger,
            substitution: substitution
        )
        let store = FakeActivationRecordStore()
        let clock = SteppingClock()
        let wholePathExecutor = FakeSelfTestExecutor()
        return AtomicityHarness(
            priorID: prior,
            candidateID: candidate,
            assembledPrior: assembledPrior,
            assembledCandidate: assembledCandidate,
            content: content,
            ledger: ledger,
            substitution: substitution,
            store: store,
            clock: clock,
            activator: ActivationHarnessBuilder.activator(
                assembled: assembledCandidate,
                content: content,
                store: store,
                clock: clock,
                executor: wholePathExecutor
            ),
            context: assembledCandidate.context,
            selfTests: tests,
            wholePathExecutor: wholePathExecutor
        )
    }

    func assembled(_ bundle: ModelBundleID) -> CompatibleCandidate {
        bundle == priorID ? assembledPrior : assembledCandidate
    }

    var weightBlobPath: CanonicalRelativePath { assembledCandidate.layout.modelWeightBlob }

    /// The real integrity verifier over the injectable content store.
    func integrityVerifier(for bundle: ModelBundleID) -> ModelBundleIntegrityVerifier {
        let source = assembled(bundle)
        return ModelBundleIntegrityVerifier(
            content: content,
            signatures: source.integrity.signatures,
            policy: source.integrity.policy,
            canonicalization: source.integrity.canonicalization
        )
    }

    /// Steps 1 through 3, for real, over the bytes the store currently serves.
    func verifiedTree(
        _ bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> VerifiedBundleArtifactTree {
        try integrityVerifier(for: bundle).verify(bundle)
    }

    /// The value steps 4 and 5 would produce, built through the module-internal initializer.
    ///
    /// Necessary rather than convenient: Requirement 10.4 pins the weight-blob digest and the
    /// approved blob is absent, so the real compatibility verifier always stops at the weight
    /// measurement for a synthetic bundle. Steps 1 through 3 are still real — the tree comes
    /// from the actual integrity verifier over the actual bytes — so every digest a receipt
    /// records is a measurement rather than a fixture constant.
    func compatible(
        _ bundle: ModelBundleID
    ) throws(ModelBundleVerificationError) -> CompatibleBundleCandidate {
        let source = assembled(bundle)
        return CompatibleBundleCandidate(
            tree: try verifiedTree(bundle),
            layout: source.layout,
            capabilityManifestID: assembledCandidate.configuration.capabilityManifest.id,
            appBuild: context.device.appBuild,
            measuredWeightDigest: RequiredPixelModel.identity.requiredWeightDigest,
            selfTests: source.plan()
        )
    }

    /// The real step 6 runner over this harness's fixtures and one programmed executor.
    func selfTestRunner(
        executor: FakeSelfTestExecutor,
        governor: StubResourceGovernor
    ) -> ReleaseSelfTestRunner {
        ReleaseSelfTestRunner(
            execution: executor,
            content: content,
            resources: governor,
            budget: assembledCandidate.configuration.resourceBudgets.mainApplication
        )
    }

    /// An executor that reports exactly what every declared case expects.
    func passingExecutor() -> FakeSelfTestExecutor {
        var observations: [String: SelfTestObservation] = [:]
        for test in selfTests {
            observations[test.fixtureID.rawValue] = SelfTestObservation(
                pixelLabel: .noStrongSignalDetected
            )
        }
        return FakeSelfTestExecutor(observations: observations)
    }

    // MARK: Observing

    func observe() async -> ObservedActivation {
        let active = await activator.activeBundle()
        let bytes = await store.publishedBytes
        let pointer = bytes.flatMap { try? FakeActivationRecordStore.decode($0) }
        return ObservedActivation(
            active: active.map(ActiveTuple.init),
            publishedPointerBytes: bytes,
            publishedBundleID: pointer?.bundleID.rawValue,
            publishedReceiptID: pointer?.receiptID.rawValue,
            publishedGeneration: pointer?.activationGeneration.value
        )
    }

    /// What one bundle's bytes currently measure to, through the real verifier.
    func measured(_ bundle: ModelBundleID) -> MeasuredBundleBytes? {
        guard let tree = try? verifiedTree(bundle),
              let fixture = content.trees[bundle.rawValue]
        else { return nil }
        return MeasuredBundleBytes(tree: tree, content: fixture)
    }

    func storeOperationCount() async -> Int {
        await store.operations.count
    }

    func storeOperations(since mark: Int) async -> [String] {
        let all = await store.operations
        guard mark <= all.count else { return [] }
        return Array(all[mark...])
    }

    func receiptCount() async -> Int {
        await store.receiptWriteOrder.count
    }

    // MARK: Nonthrowing calls

    /// The finding one whole-path activation produced, or `nil` when it activated.
    ///
    /// Wrapped rather than rethrown: an error escaping the property body would report a
    /// passing run with every arm skipped.
    func finding(
        activating bundle: ModelBundleID,
        context release: ReleaseContext
    ) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.activate(bundle, context: release)
            return nil
        } catch {
            return error
        }
    }

    /// The user-facing category one path's own entry point produced.
    func fault(
        _ path: ActivationPath,
        _ bundle: ModelBundleID,
        _ release: ReleaseContext
    ) async -> AnalysisFault? {
        do {
            switch path {
            case .newCandidate:
                _ = try await activator.activateLocalCandidate(bundle, context: release)
            case .rollback:
                _ = try await activator.rollback(to: bundle, context: release)
            }
            return nil
        } catch {
            return error
        }
    }

    func commitFinding(
        _ tested: SelfTestedBundleCandidate,
        _ release: ReleaseContext
    ) async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.commit(tested, context: release)
            return nil
        } catch {
            return error
        }
    }

    func activeFinding() async -> ModelBundleVerificationError? {
        do {
            _ = try await activator.verifiedActive(for: context)
            return nil
        } catch {
            return error
        }
    }

    /// Runs a real self-test pass and the real commit, and reports the bound bundle.
    ///
    /// The only way a synthetic bundle becomes observably active. See the file header for
    /// exactly which step is not production code.
    func activateForReal(_ bundle: ModelBundleID) async -> BoundModelBundle? {
        guard let candidate = try? compatible(bundle) else { return nil }
        let executor = passingExecutor()
        guard let tested = try? await selfTestRunner(
            executor: executor,
            governor: StubResourceGovernor()
        ).run(candidate) else { return nil }
        return try? await activator.commit(tested, context: context)
    }
}

// MARK: - One generated case, one path

/// One path's worth of arms over one harness.
private struct AtomicityScenario {
    let shape: AtomicityShape
    let path: ActivationPath
    let witness: AtomicActivationWitness
    let harness: AtomicityHarness

    /// The bundle whose complete tuple must survive every injected failure.
    let survivingID: ModelBundleID

    /// The bundle each arm attempts to activate.
    let targetID: ModelBundleID

    /// The complete tuple observers must see after every injected failure.
    let oldObservation: ObservedActivation

    /// What the surviving bundle's bytes measured to before any arm ran.
    let survivingBytes: MeasuredBundleBytes

    // MARK: Entry point

    /// Drives one path: the setup, the positive control, and every injected boundary.
    static func run(
        _ shape: AtomicityShape,
        path: ActivationPath,
        witness: AtomicActivationWitness
    ) async {
        // The control runs on its own harness, because a successful activation moves the
        // state every injected arm is measured against.
        if shape.controlRunsFirst {
            await checkAnUninjectedActivationAdvancesEverything(shape, path: path, witness: witness)
        }

        guard let scenario = await prepared(shape, path: path, witness: witness) else { return }
        for boundary in shape.boundaryOrder {
            await scenario.checkInjecting(boundary)
        }
        await scenario.checkEveryPublishedValueWasAWholePointer()
        scenario.checkNoOperationCouldHaveReachedTheNetwork()

        if !shape.controlRunsFirst {
            await checkAnUninjectedActivationAdvancesEverything(shape, path: path, witness: witness)
        }
        witness.recordPathChecked(path)
    }

    /// Builds a harness, drives it to the state this path starts from, and snapshots it.
    private static func prepared(
        _ shape: AtomicityShape,
        path: ActivationPath,
        witness: AtomicActivationWitness
    ) async -> AtomicityScenario? {
        guard let harness = AtomicityHarness.built(shape) else {
            report("a structurally valid pair of candidates must be assemblable", witness)
            return nil
        }

        // The new-candidate path starts with one bundle active and activates the other. The
        // rollback path starts with two activations behind it and returns to the first, so
        // the tuple that must survive is the *newer* one — which is what makes the rollback
        // arms a claim about atomicity rather than a claim about a clean install.
        let surviving: ModelBundleID
        let target: ModelBundleID
        switch path {
        case .newCandidate:
            surviving = harness.priorID
            target = harness.candidateID
            guard await harness.activateForReal(harness.priorID) != nil else {
                report("the prior bundle must become observably active", witness)
                return nil
            }
        case .rollback:
            surviving = harness.candidateID
            target = harness.priorID
            guard await harness.activateForReal(harness.priorID) != nil,
                  await harness.activateForReal(harness.candidateID) != nil
            else {
                report("both bundles must become observably active in turn", witness)
                return nil
            }
        }

        let observation = await harness.observe()
        guard let active = observation.active else {
            report("the surviving bundle must be observably active before any arm runs", witness)
            return nil
        }
        // The starting state is itself a complete, coherent tuple. Without this, every
        // "unchanged" assertion below would be measured against an incoherent baseline.
        #expect(active.bundleID == surviving.rawValue)
        #expect(active.memberCount == ActiveTuple.memberCount)
        #expect(observation.isCoherent, "the starting observation is a mixture: \(observation)")

        guard let bytes = harness.measured(surviving) else {
            report("the surviving bundle's bytes must be measurable", witness)
            return nil
        }

        witness.recordStartingState(path: path, generation: active.activationGeneration)
        return AtomicityScenario(
            shape: shape,
            path: path,
            witness: witness,
            harness: harness,
            survivingID: surviving,
            targetID: target,
            oldObservation: observation,
            survivingBytes: bytes
        )
    }

    // MARK: - The positive control

    /// One un-injected activation on the same path provably advances the observable state.
    ///
    /// The measurement the "unchanged" assertions are measured against. Without it, every arm
    /// above would be satisfied by an activator that never activates anything.
    private static func checkAnUninjectedActivationAdvancesEverything(
        _ shape: AtomicityShape,
        path: ActivationPath,
        witness: AtomicActivationWitness
    ) async {
        guard let harness = AtomicityHarness.built(shape) else {
            report("a structurally valid pair of candidates must be assemblable", witness)
            return
        }
        let surviving: ModelBundleID
        let target: ModelBundleID
        switch path {
        case .newCandidate:
            surviving = harness.priorID
            target = harness.candidateID
            guard await harness.activateForReal(harness.priorID) != nil else {
                report("the prior bundle must become observably active", witness)
                return
            }
        case .rollback:
            surviving = harness.candidateID
            target = harness.priorID
            guard await harness.activateForReal(harness.priorID) != nil,
                  await harness.activateForReal(harness.candidateID) != nil
            else {
                report("both bundles must become observably active in turn", witness)
                return
            }
        }

        let before = await harness.observe()
        let bytesBefore = harness.measured(surviving)
        let storeMark = await harness.storeOperationCount()
        let receiptsBefore = await harness.receiptCount()

        guard let candidate = try? harness.compatible(target) else {
            report("the target candidate must resolve for the control", witness)
            return
        }
        let executor = harness.passingExecutor()
        let governor = StubResourceGovernor()
        guard let tested = try? await harness.selfTestRunner(
            executor: executor,
            governor: governor
        ).run(candidate) else {
            report("an un-injected self-test run must pass", witness)
            return
        }
        guard await harness.commitFinding(tested, harness.context) == nil else {
            report("an un-injected commit must succeed", witness)
            return
        }

        let after = await harness.observe()
        guard let newTuple = after.active, let oldTuple = before.active else {
            report("the control must leave a complete tuple active", witness)
            return
        }

        // It advanced, and it advanced as one whole tuple.
        #expect(after != before, "the control did not change what an observer sees")
        #expect(after.isCoherent, "the control published a mixture: \(after)")
        #expect(
            newTuple.bundleID == target.rawValue,
            "the control activated \(newTuple.bundleID), expected \(target.rawValue)"
        )
        #expect(
            newTuple.activationGeneration == oldTuple.activationGeneration + 1,
            """
            the control moved the generation from \(oldTuple.activationGeneration) to \
            \(newTuple.activationGeneration)
            """
        )
        #expect(after.publishedPointerBytes != before.publishedPointerBytes)
        #expect(
            after.publishedGeneration == newTuple.activationGeneration,
            "the durable pointer and the in-memory tuple disagree about the generation"
        )
        // The admissible set really has two members, so "observers saw the old tuple" is not
        // satisfied by the old and new tuples being the same value.
        #expect(
            oldTuple != newTuple,
            "the old and new tuples are indistinguishable, so atomicity holds vacuously"
        )
        #expect(newTuple.memberCount == ActiveTuple.memberCount)

        // The reach the design fixes for a complete activation.
        let reach = ReferenceAtomicActivationModel.controlReach(
            selfTestCaseCount: shape.selfTestCaseCount
        )
        #expect(
            await harness.storeOperations(since: storeMark) == reach.durableStoreOperations,
            "the control's durable operations were not the fixed complete commit"
        )
        #expect(await harness.receiptCount() == receiptsBefore + reach.receiptsPersisted)
        #expect(executor.loadedContexts.count == reach.candidateModelLoads)
        #expect(executor.runFixtures.count == reach.fixtureRunsReached)
        #expect(executor.unloadCount == reach.candidateUnloads)
        #expect(await harness.store.leakedStagedTokens().isEmpty)

        // A successful activation does not modify the bundle it replaced either
        // (Requirement 10.16).
        #expect(
            harness.measured(surviving) == bytesBefore,
            "the replaced bundle's measured bytes changed during a successful activation"
        )

        witness.recordControl(path: path)
    }

    // MARK: - One injected boundary

    /// Injects one failure, then asserts the tuple, the prior bundle, and the reach.
    private func checkInjecting(_ boundary: InjectedBoundary) async {
        let storeMark = await harness.storeOperationCount()
        let receiptsBefore = await harness.receiptCount()
        let contentMark = harness.ledger.count

        guard let outcome = await attempt(boundary) else { return }

        // 1. The failure is the injected one, by name, and it is one category to a session.
        #expect(
            outcome.finding == outcome.expectedFinding,
            """
            \(label(boundary)) produced \(outcome.finding.map(String.init(describing:)) ?? "no finding"), \
            expected \(outcome.expectedFinding)
            """
        )
        if let produced = outcome.finding {
            // Every refusal is one category to a session: pixel inference is prevented and
            // the terminal is `model-load-error` (Requirement 10.16). The finding itself
            // stays in the release audit trail (Requirement 11.17).
            #expect(
                produced.analysisFault == .analysis(.modelLoadError, stage: .modelLoad),
                "\(label(boundary)) mapped to \(produced.analysisFault)"
            )
        }
        if let fault = outcome.portFault {
            #expect(
                fault == .analysis(.modelLoadError, stage: .modelLoad),
                "\(label(boundary)) reported \(fault) through the port"
            )
        }

        // 2. Observers still see the complete old tuple, and nothing but it.
        let after = await harness.observe()
        #expect(
            after == oldObservation,
            "\(label(boundary)) left observers \(after), expected \(oldObservation)"
        )
        #expect(after.isCoherent, "\(label(boundary)) left a mixture: \(after)")
        #expect(
            after.active?.bundleID == survivingID.rawValue,
            "\(label(boundary)) changed which bundle is active"
        )
        // And the surviving bundle is still usable, so the failure did not quietly prevent
        // inference with the bundle that was already verified (Requirement 10.16).
        #expect(
            await harness.activeFinding() == nil,
            "\(label(boundary)) left the surviving bundle unusable"
        )

        // 3. The prior bundle is unchanged, measured rather than assumed.
        #expect(
            harness.measured(survivingID) == survivingBytes,
            "\(label(boundary)) changed the surviving bundle's measured bytes"
        )

        // 4. The failure landed exactly at the injected boundary and no further.
        let reach = ReferenceAtomicActivationModel.reach(
            of: boundary,
            selfTestCaseCount: shape.selfTestCaseCount,
            failingCaseIndex: shape.failingCaseIndex
        )
        let operations = await harness.storeOperations(since: storeMark)
        #expect(
            operations == reach.durableStoreOperations,
            """
            \(label(boundary)) reached durable operations \(operations), expected \
            \(reach.durableStoreOperations)
            """
        )
        #expect(
            await harness.receiptCount() == receiptsBefore + reach.receiptsPersisted,
            "\(label(boundary)) persisted the wrong number of receipts"
        )
        #expect(
            outcome.executor?.loadedContexts.count ?? reach.candidateModelLoads
                == reach.candidateModelLoads,
            "\(label(boundary)) loaded the candidate the wrong number of times"
        )
        #expect(
            outcome.executor?.runFixtures.count ?? reach.fixtureRunsReached
                == reach.fixtureRunsReached,
            "\(label(boundary)) reached the wrong number of fixtures"
        )
        #expect(
            outcome.executor?.unloadCount ?? reach.candidateUnloads == reach.candidateUnloads,
            "\(label(boundary)) left the candidate loaded"
        )
        #expect(
            await harness.store.leakedStagedTokens().isEmpty,
            "\(label(boundary)) left staged state a later launch could mistake for a pointer"
        )

        // The surviving bundle's own tree is never touched while the other one is verified.
        // The re-measurement above reads it, so only the attempt's own delta is inspected.
        let touched = harness.ledger.delta(since: contentMark)
            .prefix(outcome.contentOperationCount)
            .filter { $0.contains(survivingID.rawValue) }
        #expect(
            touched.isEmpty,
            "\(label(boundary)) read the surviving bundle: \(Array(touched))"
        )

        witness.recordInjectedBoundary(boundary, path: path, finding: outcome.expectedFinding)
    }

    /// What one injected attempt produced.
    private struct Outcome {
        let finding: ModelBundleVerificationError?
        let expectedFinding: ModelBundleVerificationError
        /// `nil` for boundaries that never reach the self-test runner.
        let executor: FakeSelfTestExecutor?
        /// The port-level category, where the boundary is reachable through a port member.
        let portFault: AnalysisFault?
        /// Content operations the attempt itself performed, so the re-measurement's reads are
        /// excluded from the surviving-bundle check.
        let contentOperationCount: Int
    }

    /// Performs one injection and returns what it produced.
    private func attempt(_ boundary: InjectedBoundary) async -> Outcome? {
        switch boundary {
        case .integrityVerification:
            return await attemptIntegrityInjection()
        case .compatibilityVerification:
            return await attemptCompatibilityInjection()
        case .candidateModelLoad:
            return await attemptSelfTestInjection(failingTheLoad: true)
        case .releaseSelfTest:
            return await attemptSelfTestInjection(failingTheLoad: false)
        case .receiptPersistence:
            return await attemptStepSevenInjection(boundary, at: .persistReceipt)
        case .pointerStaging:
            return await attemptStepSevenInjection(boundary, at: .stagePointer)
        case .stateSynchronization:
            return await attemptStepSevenInjection(boundary, at: .synchronize)
        case .pointerReplacement:
            return await attemptStepSevenInjection(boundary, at: .publish)
        }
    }

    /// Step 3: one declared artifact's bytes change at the same length.
    private func attemptIntegrityInjection() async -> Outcome? {
        let target = IntegrityMutationTarget.allCases[
            shape.mutationTargetIndex % IntegrityMutationTarget.allCases.count
        ]
        guard let firstFixture = shape.selfTests.first?.suiteRelativePath else {
            report("every generated case declares at least one fixture")
            return nil
        }
        let mutatedPath = target.mutatedPath(firstFixturePath: firstFixture)
        guard let original = harness.content.trees[targetID.rawValue]?
            .fileBytes[mutatedPath],
            !original.isEmpty
        else {
            report("the mutation target \(mutatedPath) must exist in the candidate")
            return nil
        }
        // One byte, flipped in its lowest bit, so the replacement is the same length and
        // always differs. Only a digest over the declared artifact can catch it.
        var replacement = original
        let position = shape.mutationByteIndex % replacement.count
        replacement[position] ^= 0x01
        guard replacement != original else {
            report("the generated mutation must change the bytes")
            return nil
        }

        let mark = harness.ledger.count
        harness.substitution.substitute(replacement, at: mutatedPath, in: targetID)
        let fault = await harness.fault(path, targetID, harness.context)
        let finding = await harness.finding(activating: targetID, context: harness.context)
        harness.substitution.clear()
        let consumed = harness.ledger.count - mark

        // The candidate really was streamed, so the refusal is a measurement rather than a
        // check that never ran.
        let readTheCandidate = harness.ledger.delta(since: mark)
            .contains { $0.hasPrefix("read:\(targetID.rawValue):") }
        #expect(readTheCandidate, "the integrity boundary never streamed the candidate")

        return Outcome(
            finding: finding,
            expectedFinding: .artifactDigestMismatch(Sample.path(target.declaredArtifactPath)),
            executor: harness.wholePathExecutor,
            portFault: fault,
            contentOperationCount: consumed
        )
    }

    /// Step 5: the running build is not one the bundle declares compatibility with.
    private func attemptCompatibilityInjection() async -> Outcome? {
        let foreign = shape.foreignContext
        #expect(
            !harness.assembled(targetID).integrity.manifest.compatibility
                .compatibleAppBuilds.contains(shape.foreignAppBuild),
            "the generated foreign build must be outside the bundle's compatibility matrix"
        )
        let mark = harness.ledger.count
        let fault = await harness.fault(path, targetID, foreign)
        let finding = await harness.finding(activating: targetID, context: foreign)
        let consumed = harness.ledger.count - mark
        return Outcome(
            finding: finding,
            expectedFinding: .appBuildNotCompatible(shape.foreignAppBuild),
            executor: harness.wholePathExecutor,
            portFault: fault,
            contentOperationCount: consumed
        )
    }

    /// Step 6: the load boundary, or the comparison boundary.
    private func attemptSelfTestInjection(failingTheLoad: Bool) async -> Outcome? {
        guard let candidate = try? harness.compatible(targetID) else {
            report("the target candidate must resolve before its self-tests run")
            return nil
        }
        let executor = harness.passingExecutor()
        let expected: ModelBundleVerificationError
        if failingTheLoad {
            executor.loadFault = .modelLoadFailed
            expected = .selfTestCandidateLoadFailed(targetID)
        } else {
            let failing = shape.selfTests[shape.failingCaseIndex]
            executor.observations[failing.fixtureID.rawValue] = SelfTestObservation(
                pixelLabel: shape.reportedWrongLabel
            )
            #expect(
                shape.reportedWrongLabel != shape.declaredLabel,
                "the generated reported label must disagree with the declared one"
            )
            expected = .selfTestExpectationMismatch(case: failing.caseID, kind: .pixelLabel)
        }

        let mark = harness.ledger.count
        let governor = StubResourceGovernor()
        let finding: ModelBundleVerificationError?
        do {
            _ = try await harness.selfTestRunner(executor: executor, governor: governor)
                .run(candidate)
            finding = nil
        } catch {
            finding = error
        }
        let consumed = harness.ledger.count - mark

        // The budget really was sampled, so a load refusal is not a run that skipped the
        // governed step (Requirement 10.11).
        #expect(
            !governor.log.observed.isEmpty,
            "the self-test run never sampled the approved budget"
        )
        return Outcome(
            finding: finding,
            expectedFinding: expected,
            executor: executor,
            portFault: nil,
            contentOperationCount: consumed
        )
    }

    /// Step 7: one durable boundary, reached with a real self-test pass behind it.
    private func attemptStepSevenInjection(
        _ boundary: InjectedBoundary,
        at point: FakeActivationRecordStore.FailurePoint
    ) async -> Outcome? {
        guard let candidate = try? harness.compatible(targetID) else {
            report("the target candidate must resolve before step 7")
            return nil
        }
        let executor = harness.passingExecutor()
        let mark = harness.ledger.count
        guard let tested = try? await harness.selfTestRunner(
            executor: executor,
            governor: StubResourceGovernor()
        ).run(candidate) else {
            report("the self-test run before step 7 must pass")
            return nil
        }

        // Named before the attempt: a receipt-write failure reports the identifier that
        // attempt derives, and the derivation carries the instant the activation reads. The
        // generation is one past the published one, which is what the design fixes.
        let expected: ModelBundleVerificationError
        if point == .persistReceipt {
            guard let generation = oldObservation.publishedGeneration,
                  let next = try? PositiveCount(validating: generation + 1),
                  let id = ModelBundleActivator.receiptIdentity(
                      bundle: targetID,
                      generation: next,
                      at: harness.clock.nextReading
                  )
            else {
                report("the receipt identifier this attempt derives must be nameable")
                return nil
            }
            // An audit reads which bundle and which generation a receipt belongs to straight
            // off the identifier, so the derived text carries both.
            #expect(id.rawValue.contains(targetID.rawValue))
            #expect(id.rawValue.contains(".\(next.value)."))
            expected = .activationReceiptNotPersisted(id)
        } else {
            expected = switch point {
            case .stagePointer: .activationPointerNotStaged(targetID)
            case .synchronize: .activationStateNotSynchronized(targetID)
            case .publish: .activationPointerNotReplaced(targetID)
            case .readPointer, .persistReceipt: .activationRecordStoreUnavailable
            }
        }

        await harness.store.fail(at: point)
        let finding = await harness.commitFinding(tested, harness.context)
        await harness.store.succeed(at: point)
        let consumed = harness.ledger.count - mark

        if point == .persistReceipt {
            // The write was attempted under exactly the identifier the arm named, so the
            // refusal is about that record rather than about some other identifier.
            #expect(
                await harness.store.attemptedReceiptIdentifiers.last.map(\.rawValue)
                    == expected.attemptedReceiptIdentifier,
                "the receipt write was attempted under an unexpected identifier"
            )
        }
        return Outcome(
            finding: finding,
            expectedFinding: expected,
            executor: executor,
            portFault: nil,
            contentOperationCount: consumed
        )
    }

    // MARK: - Whole-history checks

    /// Every value the published slot has ever held is a complete pointer naming a persisted
    /// receipt.
    ///
    /// The durable half of "never a mixture": a half-written pointer, or one naming a record
    /// that never reached storage, would show up here even though the final state looks fine.
    private func checkEveryPublishedValueWasAWholePointer() async {
        let history = await harness.store.publishedHistory
        let receipts = await harness.store.receipts
        #expect(history.first ?? nil == nil, "the published slot must start empty")
        var published: [String] = []
        for bytes in history.dropFirst() {
            guard let raw = bytes,
                  let pointer = try? FakeActivationRecordStore.decode(raw)
            else {
                Issue.record("the published slot held a value that is not a complete pointer")
                continue
            }
            guard let receipt = receipts[pointer.receiptID.rawValue] else {
                Issue.record("a published pointer named a receipt that never reached storage")
                continue
            }
            #expect(pointer.bundleID == receipt.bundleID)
            #expect(pointer.activationGeneration == receipt.activationGeneration)
            published.append("\(pointer.bundleID.rawValue)@\(pointer.activationGeneration.value)")
        }
        // The setup published one value per path step and no arm added another.
        let expectedPublications = path == .rollback ? 2 : 1
        #expect(
            published.count == expectedPublications,
            "the published slot moved \(published.count) time(s), expected \(expectedPublications)"
        )
        #expect(
            Set(published).count == published.count,
            "two published pointers were indistinguishable: \(published)"
        )
        witness.recordPublicationHistory(path: path, count: published.count)
    }

    /// Nothing either seam was asked for could have named, discovered, or fetched a bundle.
    ///
    /// Requirements 10.19 and 10.21 in the form this file can observe: a closed operation
    /// vocabulary on both seams, over exactly the two locally installed identifiers. There is
    /// no runtime network seam in this module, so nothing here claims to have watched one.
    private func checkNoOperationCouldHaveReachedTheNetwork() {
        let installed = [harness.priorID.rawValue, harness.candidateID.rawValue]
        var contentVerbs: Set<String> = []
        for entry in harness.ledger.delta(since: 0) {
            let parts = entry.split(separator: ":", maxSplits: 2).map(String.init)
            guard let verb = parts.first, parts.count >= 2 else {
                Issue.record("an unrecognized content operation was recorded: \(entry)")
                continue
            }
            contentVerbs.insert(verb)
            #expect(
                installed.contains(parts[1]),
                "a content operation named \(parts[1]), which is not locally installed"
            )
        }
        #expect(
            contentVerbs.isSubset(of: ["enumerate", "read"]),
            "the content seam was asked for \(contentVerbs.sorted())"
        )
        witness.recordSeamVocabulary(content: contentVerbs)
    }

    // MARK: - Rollback runs the identical path

    /// The two port entry points do the identical work over the same bundle from the same
    /// state (Requirement 10.17).
    ///
    /// Two harnesses in lockstep, one driven through
    /// ``ModelBundleActivator/activateLocalCandidate(_:context:)`` and one through
    /// ``ModelBundleActivator/rollback(to:context:)``, over the same bundle, with the same
    /// injection and then without it. Equal recorded content work means the same reads in the
    /// same order over the same bytes; equal durable work means neither entry point has a
    /// commit of its own; equal findings mean neither has a shortcut.
    ///
    /// This is the deepest boundary the whole path can reach for a synthetic candidate — the
    /// pinned weight digest of Requirement 10.4 stops both — so it establishes entry-point
    /// identity across steps 1 through 5. Step 7's identity is structural: `rollback` and
    /// `activateLocalCandidate` are two names for one call, and both reach step 7 only through
    /// ``ModelBundleActivator/commit(_:context:)``, which the step-7 arms above exercise once
    /// per path.
    static func checkRollbackTakesTheIdenticalPath(
        _ shape: AtomicityShape,
        witness: AtomicActivationWitness
    ) async {
        guard let activating = AtomicityHarness.built(shape),
              let rollingBack = AtomicityHarness.built(shape)
        else {
            report("a structurally valid pair of candidates must be assemblable", witness)
            return
        }
        // The same bundle on both, so the recorded work is comparable at all.
        let bundle = activating.priorID
        #expect(bundle == rollingBack.priorID)

        // First with an injected integrity failure, then without one, so identity is
        // established at a refusal that this file caused and at the structural terminal.
        let target = IntegrityMutationTarget.allCases[
            shape.mutationTargetIndex % IntegrityMutationTarget.allCases.count
        ]
        guard let firstFixture = shape.selfTests.first?.suiteRelativePath else {
            report("every generated case declares at least one fixture", witness)
            return
        }
        let mutatedPath = target.mutatedPath(firstFixturePath: firstFixture)
        guard let original = activating.content.trees[bundle.rawValue]?.fileBytes[mutatedPath],
              !original.isEmpty
        else {
            report("the mutation target must exist in the rollback candidate", witness)
            return
        }
        var replacement = original
        replacement[shape.mutationByteIndex % replacement.count] ^= 0x01

        for injected in [true, false] {
            if injected {
                activating.substitution.substitute(replacement, at: mutatedPath, in: bundle)
                rollingBack.substitution.substitute(replacement, at: mutatedPath, in: bundle)
            } else {
                activating.substitution.clear()
                rollingBack.substitution.clear()
            }
            let activatingMark = activating.ledger.count
            let rollingBackMark = rollingBack.ledger.count

            let activatingFault = await activating.fault(.newCandidate, bundle, activating.context)
            let rollingBackFault = await rollingBack.fault(.rollback, bundle, rollingBack.context)

            let expected: ModelBundleVerificationError = injected
                ? .artifactDigestMismatch(Sample.path(target.declaredArtifactPath))
                : .modelWeightDigestMismatch(activating.weightBlobPath)
            let activatingFinding = await activating.finding(
                activating: bundle,
                context: activating.context
            )
            let rollingBackFinding = await rollingBack.finding(
                activating: bundle,
                context: rollingBack.context
            )

            #expect(
                activatingFault == .analysis(.modelLoadError, stage: .modelLoad),
                "activation reported \(String(describing: activatingFault))"
            )
            #expect(
                rollingBackFault == activatingFault,
                "rollback reported \(String(describing: rollingBackFault)) where activation reported \(String(describing: activatingFault))"
            )
            #expect(activatingFinding == expected, "activation stopped at the wrong step")
            #expect(
                rollingBackFinding == activatingFinding,
                "rollback stopped at a different step than activation"
            )

            let activatingWork = activating.ledger.delta(since: activatingMark)
            let rollingBackWork = rollingBack.ledger.delta(since: rollingBackMark)
            #expect(!activatingWork.isEmpty, "neither entry point read anything")
            #expect(
                rollingBackWork == activatingWork,
                "rollback performed different content work than activation"
            )
            // Neither entry point reached the record store, and neither activated anything.
            #expect(await activating.storeOperations(since: 0).isEmpty)
            #expect(await rollingBack.storeOperations(since: 0).isEmpty)
            #expect(await activating.activator.activeBundle() == nil)
            #expect(await rollingBack.activator.activeBundle() == nil)
            #expect(await activating.store.publishedBytes == nil)
            #expect(await rollingBack.store.publishedBytes == nil)

            witness.recordEntryPointIdentity(injected: injected, workCount: activatingWork.count)
        }
    }

    // MARK: - Helpers

    private func label(_ boundary: InjectedBoundary) -> String {
        "\(path.rawValue)/\(boundary.rawValue)"
    }

    private func report(_ message: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        Self.report(message, witness, sourceLocation: sourceLocation)
    }

    /// Records that a fixture this file described could not be built.
    ///
    /// Never a finding about activation: every input here is built from generated integers
    /// inside validated ranges, so a refusal is a defect in this file. It is counted so a run
    /// whose inputs quietly stopped being buildable fails outside the body rather than
    /// shrinking its own coverage.
    private static func report(
        _ message: Comment,
        _ witness: AtomicActivationWitness,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        witness.recordUnbuildableInput()
        Issue.record(message, sourceLocation: sourceLocation)
    }
}

// MARK: - Reading one finding's receipt identifier

extension ModelBundleVerificationError {
    /// The receipt identifier a receipt-write refusal names, if it names one.
    ///
    /// Read off the finding rather than reconstructed, so the cross-check against the store's
    /// attempted identifiers compares two independently obtained values.
    fileprivate var attemptedReceiptIdentifier: String? {
        switch self {
        case let .activationReceiptNotPersisted(id): id.rawValue
        case let .activationReceiptConflict(id): id.rawValue
        default: nil
        }
    }
}

// MARK: - The variation witness

/// Counts what the run generated and what it produced, outside the property body.
///
/// `propertyCheck` runs its body under `try?`, so a body that failed before its first
/// assertion reports a passing test in milliseconds with every arm skipped. Two habits close
/// that gap, and both matter:
///
///   * every arm counter is compared against the **case count** rather than against a floor,
///     so a run in which an arm stopped being reached fails even if the absolute number still
///     looks large; and
///   * ``recordCompletedBody()`` is the last thing the body does, so a case that ended early
///     is countable. `completedBodies == cases` alone would pass vacuously as `0 == 0`, which
///     is why the case floor sits beside it.
///
/// The produced sets are the substantive half. Every boundary must actually have been injected
/// on both paths, every boundary must actually have produced its own finding vocabulary, and
/// the positive control must actually have advanced the state on both paths — which is what
/// turns an assertion about absences into a claim about produced outcomes.
private final class AtomicActivationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // Arm counters.
    private var cases = 0
    private var completedBodies = 0
    private var pathsChecked = 0
    private var startingStates = 0
    private var injectedArms = 0
    private var controls = 0
    private var publicationHistories = 0
    private var seamVocabularyChecks = 0
    private var entryPointIdentityChecks = 0
    private var unbuildableInputs = 0

    // Produced outcomes.
    private var boundariesByPath: [String: Set<String>] = [:]
    private var findingsByBoundary: [String: Set<String>] = [:]
    private var controlledPaths: Set<String> = []
    private var startingGenerations: [String: Set<Int>] = [:]
    private var contentVerbs: Set<String> = []
    private var injectedIdentityRuns: Set<Bool> = []

    // Generated baseline.
    private var seeds: Set<Int> = []
    private var selfTestCounts: Set<Int> = []
    private var failingCaseIndices: Set<Int> = []
    private var wrongLabels: Set<String> = []
    private var mutationTargets: Set<String> = []
    private var foreignBuilds: Set<String> = []
    private var compiledModelContents: Set<String> = []
    private var weightBlobContents: Set<String> = []
    private var firstBoundaries: Set<String> = []
    private var pathOrders: Set<Bool> = []
    private var controlOrders: Set<Bool> = []

    func record(_ shape: AtomicityShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        selfTestCounts.insert(shape.selfTestCaseCount)
        failingCaseIndices.insert(shape.failingCaseIndex)
        wrongLabels.insert(shape.reportedWrongLabel.rawValue)
        mutationTargets.insert(
            IntegrityMutationTarget.allCases[
                shape.mutationTargetIndex % IntegrityMutationTarget.allCases.count
            ].rawValue
        )
        foreignBuilds.insert(shape.foreignAppBuild.rawValue)
        compiledModelContents.insert(
            String(decoding: shape.compiledModelDataBytes, as: UTF8.self)
        )
        weightBlobContents.insert(String(decoding: shape.weightBlobBytes, as: UTF8.self))
        if let first = shape.boundaryOrder.first { firstBoundaries.insert(first.rawValue) }
        pathOrders.insert(shape.rollbackPathRunsFirst)
        controlOrders.insert(shape.controlRunsFirst)
    }

    func recordPathChecked(_ path: ActivationPath) {
        lock.lock()
        pathsChecked += 1
        lock.unlock()
    }

    func recordStartingState(path: ActivationPath, generation: Int) {
        lock.lock()
        startingStates += 1
        startingGenerations[path.rawValue, default: []].insert(generation)
        lock.unlock()
    }

    func recordInjectedBoundary(
        _ boundary: InjectedBoundary,
        path: ActivationPath,
        finding: ModelBundleVerificationError
    ) {
        lock.lock()
        injectedArms += 1
        boundariesByPath[path.rawValue, default: []].insert(boundary.rawValue)
        findingsByBoundary[boundary.rawValue, default: []].insert(
            Self.findingVocabulary(finding)
        )
        lock.unlock()
    }

    func recordControl(path: ActivationPath) {
        lock.lock()
        controls += 1
        controlledPaths.insert(path.rawValue)
        lock.unlock()
    }

    func recordPublicationHistory(path: ActivationPath, count: Int) {
        lock.lock()
        publicationHistories += 1
        lock.unlock()
    }

    func recordSeamVocabulary(content: Set<String>) {
        lock.lock()
        seamVocabularyChecks += 1
        contentVerbs.formUnion(content)
        lock.unlock()
    }

    func recordEntryPointIdentity(injected: Bool, workCount: Int) {
        lock.lock()
        entryPointIdentityChecks += 1
        injectedIdentityRuns.insert(injected)
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

    /// One finding's case name, without its payload.
    ///
    /// The payload varies per case — a generated build, a derived receipt identifier — so the
    /// coverage set is over the *kind* of refusal each boundary produced.
    private static func findingVocabulary(_ finding: ModelBundleVerificationError) -> String {
        switch finding {
        case .artifactDigestMismatch: "artifactDigestMismatch"
        case .appBuildNotCompatible: "appBuildNotCompatible"
        case .selfTestCandidateLoadFailed: "selfTestCandidateLoadFailed"
        case .selfTestExpectationMismatch: "selfTestExpectationMismatch"
        case .activationReceiptNotPersisted: "activationReceiptNotPersisted"
        case .activationPointerNotStaged: "activationPointerNotStaged"
        case .activationStateNotSynchronized: "activationStateNotSynchronized"
        case .activationPointerNotReplaced: "activationPointerNotReplaced"
        default: "unexpected:\(finding)"
        }
    }

    /// The finding each boundary must have produced, written beside the reference reach table
    /// so a boundary that started producing some other refusal fails here.
    private static let expectedFindings: [String: String] = [
        InjectedBoundary.integrityVerification.rawValue: "artifactDigestMismatch",
        InjectedBoundary.compatibilityVerification.rawValue: "appBuildNotCompatible",
        InjectedBoundary.candidateModelLoad.rawValue: "selfTestCandidateLoadFailed",
        InjectedBoundary.releaseSelfTest.rawValue: "selfTestExpectationMismatch",
        InjectedBoundary.receiptPersistence.rawValue: "activationReceiptNotPersisted",
        InjectedBoundary.pointerStaging.rawValue: "activationPointerNotStaged",
        InjectedBoundary.stateSynchronization.rawValue: "activationStateNotSynchronized",
        InjectedBoundary.pointerReplacement.rawValue: "activationPointerNotReplaced",
    ]

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        let boundaryCount = InjectedBoundary.allCases.count
        let pathCount = ActivationPath.allCases.count

        #expect(cases >= 100, "the design requires at least 100 generated cases; ran \(cases)")
        #expect(
            completedBodies == cases,
            "\(cases - completedBodies) of \(cases) cases did not reach the end of the body"
        )
        #expect(
            unbuildableInputs == 0,
            "\(unbuildableInputs) described inputs could not be built at all"
        )

        // Every arm ran on every case. Compared against the case count rather than against a
        // floor: an arm that stopped being reached fails here even when the absolute number
        // still looks large.
        #expect(pathsChecked == cases * pathCount, "paths checked: \(pathsChecked)")
        #expect(startingStates == cases * pathCount, "starting states: \(startingStates)")
        #expect(
            injectedArms == cases * pathCount * boundaryCount,
            "injected arms: \(injectedArms), expected \(cases * pathCount * boundaryCount)"
        )
        #expect(controls == cases * pathCount, "positive controls: \(controls)")
        #expect(
            publicationHistories == cases * pathCount,
            "publication histories inspected: \(publicationHistories)"
        )
        #expect(
            seamVocabularyChecks == cases * pathCount,
            "seam vocabulary checks: \(seamVocabularyChecks)"
        )
        #expect(
            entryPointIdentityChecks == cases * 2,
            "entry-point identity checks: \(entryPointIdentityChecks)"
        )

        // The substantive half: the outcomes were produced, not merely offered.
        let everyBoundary = Set(InjectedBoundary.allCases.map(\.rawValue))
        for path in ActivationPath.allCases {
            let reached = boundariesByPath[path.rawValue] ?? []
            #expect(
                reached == everyBoundary,
                """
                boundaries never injected on the \(path.rawValue) path: \
                \(everyBoundary.subtracting(reached).sorted())
                """
            )
        }
        #expect(
            controlledPaths == Set(ActivationPath.allCases.map(\.rawValue)),
            "paths whose positive control never ran: \(controlledPaths)"
        )
        for (boundary, expected) in Self.expectedFindings {
            #expect(
                findingsByBoundary[boundary] == [expected],
                """
                the \(boundary) boundary produced \
                \((findingsByBoundary[boundary] ?? []).sorted()), expected [\(expected)]
                """
            )
        }
        // The rollback path really did start from a later activation than the new-candidate
        // path, so its arms are a claim about replacing a bundle rather than about a clean
        // install.
        #expect(
            startingGenerations[ActivationPath.newCandidate.rawValue] == [1],
            "new-candidate starting generations: \(startingGenerations[ActivationPath.newCandidate.rawValue] ?? [])"
        )
        #expect(
            startingGenerations[ActivationPath.rollback.rawValue] == [2],
            "rollback starting generations: \(startingGenerations[ActivationPath.rollback.rawValue] ?? [])"
        )
        #expect(
            contentVerbs == ["enumerate", "read"],
            "content seam verbs actually exercised: \(contentVerbs.sorted())"
        )
        #expect(
            injectedIdentityRuns == [false, true],
            "the entry-point identity arm did not run both injected and un-injected"
        )

        // The generated baseline actually varied.
        #expect(seeds.count >= 50, "generated seeds: \(seeds.count)")
        #expect(selfTestCounts == [1, 2], "generated self-test case counts: \(selfTestCounts.sorted())")
        #expect(
            failingCaseIndices == [0, 1],
            "generated failing case indices: \(failingCaseIndices.sorted())"
        )
        #expect(
            wrongLabels == ["not-enough-signal", "signals-consistent-with-ai-generation"],
            "generated reported labels: \(wrongLabels.sorted())"
        )
        #expect(
            mutationTargets == Set(IntegrityMutationTarget.allCases.map(\.rawValue)),
            "generated mutation targets: \(mutationTargets.sorted())"
        )
        #expect(foreignBuilds.count >= 50, "generated foreign builds: \(foreignBuilds.count)")
        #expect(
            compiledModelContents.count >= 50,
            "generated compiled-model contents: \(compiledModelContents.count)"
        )
        #expect(
            weightBlobContents.count >= 50,
            "generated weight-blob contents: \(weightBlobContents.count)"
        )
        #expect(
            firstBoundaries == everyBoundary,
            """
            boundaries that never ran first: \
            \(everyBoundary.subtracting(firstBoundaries).sorted())
            """
        )
        #expect(pathOrders == [false, true], "only one path order was generated")
        #expect(controlOrders == [false, true], "only one control order was generated")
    }
}
