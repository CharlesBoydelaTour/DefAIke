import DefAIkeDomain
import CoreGraphics
import Foundation
import ImageIO
import PropertyBased
import Testing
import UniformTypeIdentifiers

@testable import DefAIkeImagePipeline

// Design Property 10: Metadata handling is total and contract-driven.
//
// The design states it as: for any Preprocessing Contract and any orientation,
// embedded-profile, or alpha metadata state in valid, absent, malformed, or unsupported
// form, the contract is activatable only when it defines exactly one action for that
// state, and preprocessing selects that action without an implicit fallback.
//
// That is two claims about two different moments, and this file proves each one as a
// negative rather than as a happy path.
//
//   * **Activation.** A map that does not bind the state exactly once must be *refused*,
//     not quietly completed. Proved by removing exactly one state's entry — and,
//     separately, by binding one state twice — and showing the refusal at all three
//     layers a contract can arrive through: the schema initializer, a decode of the
//     signed artifact bytes, and the adapter-side check the transform performs on the
//     rule list it was handed. Each refusal is asserted to name the removed or duplicated
//     state, and each is paired with a positive control on the untouched map, so a
//     blanket "nothing decodes" would fail rather than pass.
//   * **Action selection.** At run time the action comes from the map entry for the
//     observed state. There is no fallback, no "default to ignore", and no nearest match.
//     Proved twice over. Directly: ``MetadataActionBinding/bind(_:contract:)`` returns
//     the entry for the observed state, and returns a *different* action when handed a
//     different observed state over the same contract — which no constant, no first-entry
//     lookup, and no nearest-match rule can do. Behaviourally: rendering under a contract
//     whose other three states name a deliberately different action is byte-identical to
//     rendering under a contract that names only the selected action, and — wherever the
//     two actions are measurably different on this input — is *not* the result the other
//     entry would have produced.
//
// The behavioural half is what rules out an implicit default that happens to agree with
// the map. The generated contract and the reference contract differ in three of the four
// entries of every field's map; if selection read anything but the observed state's entry,
// the two would disagree.
//
// ## What is real here and what is not
//
// The Preprocessor, the working-space renderer, the metadata inspector, and the Input
// Validator are the real adapters over real Image I/O, Core Graphics, ColorSync, and
// Accelerate. Nothing is doubled.
//
// Metadata states arrive two ways, and the difference is stated per case rather than
// blurred:
//
//   * **Measured.** A real container's bytes, whose declarations are read back out of the
//     container and whose observed triple is recomputed by the real inspector on every
//     generated case before anything is asserted. These cases additionally run the whole
//     ``ContractImagePreprocessor`` end to end, which is what proves the state the map is
//     indexed by is the state the adapter really observed from bytes rather than one a
//     test handed it.
//   * **Stated.** An ``ObservedImageMetadata`` value constructed directly over a real
//     decoded image, for the states no encoder on this host will put into a container.
//     ``ImageMetadataInspector`` documents why those branches exist and why they are
//     unreachable from an encoder: Image I/O normalizes an out-of-range orientation while
//     writing, a rejected profile chunk is reported as no profile at all, and an alpha
//     arrangement this build cannot name cannot be put into a `CGImage`. Requirement 3.7
//     covers all four states of all three fields, so a property that only exercised the
//     expressible ones would leave a third of the requirement unquantified.
//
// ``MetadataCatalog`` discovers which containers this host can actually express and drops
// the rest instead of substituting a stand-in, and ``MetadataVariationWitness`` reports
// both counts after the run.
//
// `ContractMetadataTransformTests` pins totality, selection, each refusing action, the
// two profile actions, and both alpha actions with one example each. This file quantifies
// the same statement over generated action assignments, over every state of every field,
// over generated dimensions, and over the removal or duplication of each state's entry in
// turn, and it is the only file here that asserts a mutated *artifact payload* is refused
// and that selection tracks the observed state rather than the map's other entries.
//
// Scope: the exactness of the pre-orientation record is Property 9's, the ordering of
// validation and inference is Property 8's, and resize and crop geometry is Property 12's.
// Which action a release should bind to which state is decision D10 and is not asserted
// anywhere here; what is asserted is only that whatever the contract names is what runs.
// The real-framework colour, alpha, grayscale, and wide-gamut comparisons against approved
// tolerances belong to the Release Fixture Suite (task 5.10) and are not attempted here.
//
// **No value in this file is an approved release value.** Every metadata action, working
// space, background colour, and resource limit is a synthetic argument that exists so a
// port taking a signed artifact can be called at all. Several are deliberately
// inapplicable, which is the point of the runs that use them. Nothing here may be copied
// into a shipping artifact.

extension Tag {
    /// Design Property 10.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property10MetadataHandlingIsTotalAndContractDriven: Self
}

@Suite(
    "Property 10: Metadata handling is total and contract-driven",
    .tags(.property10MetadataHandlingIsTotalAndContractDriven)
)
struct TotalContractDrivenMetadataPropertyTests {
    /// Runs 400 generated cases with shrinking, above the design's floor of 100.
    ///
    /// The count is raised rather than left at the library default because of what this
    /// property has to quantify over. Requirement 3.7 names four states for each of three
    /// fields, and six of those twelve `(field, state)` pairs are reachable from exactly one
    /// arm each — the states no encoder on this host writes into a container, which only a
    /// stated arm can present. With the catalogue's arms drawn uniformly, one specific arm
    /// is missed by a 100-case run about 5% of the time, so requiring all six is a coverage
    /// assertion that fails roughly one run in five for no reason but the draw. Measured
    /// over sixteen 100-case runs on this host, three would have failed exactly that way.
    ///
    /// Four hundred cases drops the chance of missing any one of them to a few parts in a
    /// hundred thousand, which makes the strong statement — every state of every field was
    /// really presented, and every one of the twelve entries was really attacked at
    /// activation — sound to assert rather than something to weaken into a floor. It also
    /// puts the runtime alongside the other property tests in this module, which is itself
    /// evidence the body ran: a body whose work was skipped finishes in milliseconds.
    ///
    /// **Validates: Requirements 3.7, 3.8**
    @Test("A metadata map is activatable only when total, and selection has no default")
    func metadataHandlingIsTotalAndHasNoImplicitDefault() async {
        let witness = MetadataVariationWitness()

        await propertyCheck(count: 400, input: MetadataShape.generator) { shape in
            witness.record(shape)
            let scenario = MetadataScenario(shape: shape, witness: witness)

            // Activation first, because it is the claim that decides whether the second
            // one is ever reached: a contract with a gap must not exist to be applied.
            scenario.checkAnIncompleteMapIsRefusedAtActivation()

            guard let observed = await scenario.measureObservedMetadata() else { return }
            scenario.checkBindingReadsTheObservedStateAndNothingElse(observed)
            await scenario.checkRenderingFollowsTheObservedStatesEntry(observed)
            await scenario.checkTheWholePreprocessorFollowsTheSameEntry(observed)
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - The three fields the contract governs

/// One metadata field whose handling the contract fixes.
///
/// Requirement 3.7 names exactly these three. The raw value is the encoded artifact key,
/// because the activation half mutates the payload at that key and a mistyped key would
/// silently mutate nothing.
private enum MetadataField: String, Hashable, Sendable, CaseIterable {
    case orientation = "orientationRules"
    case colorProfile = "colorProfileRules"
    case alpha = "alphaRules"
}

/// The field this schema names when a rule map is not total.
///
/// Read from one place so the activation assertions cannot drift from the schema's own
/// wording.
private let metadataRuleField = "metadataStateRules"

// MARK: - Action catalogues

/// The actions each field can name, as closed lists the generator indexes into.
///
/// Every member of every list is exercised as both a selected and a foil action; the
/// witness holds the run to that. The refusing member is included deliberately: applying
/// it *is* returning `preprocessing-error` (Requirement 3.11), so it is one of the
/// contract's actions rather than a failure mode, and a selection rule that skipped it
/// would be selecting something the contract did not name.
private enum MetadataActionCatalogue {
    static let orientation: [OrientationAction] = OrientationAction.allCases

    static let colorProfile: [ColorProfileAction] = ColorProfileAction.allCases

    /// Alpha actions, with the composite background derived from the case's seed.
    ///
    /// ``AlphaAction`` carries an explicit opaque background rather than defaulting to
    /// white or black, so there is no fixed list to enumerate. Deriving the colour from
    /// the seed means a "composite over black whatever the contract says" implementation
    /// fails on nearly every case instead of on none.
    static func alpha(seed: Int) -> [AlphaAction] {
        [
            .discardAlphaChannel,
            .compositeOverOpaqueBackground(
                OpaqueBackgroundColor(
                    red: UInt8(seed % 251),
                    green: UInt8((seed / 251) % 251),
                    blue: UInt8((seed / 7) % 251)
                )
            ),
            .rejectAsPreprocessingError,
        ]
    }
}

// MARK: - Source images

/// Pixels for the directly constructed decoded sources.
///
/// Local to this file rather than added to the shared fixtures, which this task may read
/// but not edit. The patterns are deliberately not flat: a constant image would hide a
/// colour conversion, a composite, and a permutation all at once.
private enum MetadataSourcePixels {
    /// Interleaved RGBA whose alpha genuinely varies, so compositing and discarding are
    /// distinguishable results rather than the same bytes twice.
    static func varyingAlpha(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 37 + y * 11) & 0xFF)
                pixels[offset + 1] = UInt8((x * 5 + y * 71) & 0xFF)
                pixels[offset + 2] = UInt8((x ^ y) & 0xFF)
                // Never fully opaque, so every pixel carries a composite/discard
                // difference; never fully transparent, so the colour channels survive.
                pixels[offset + 3] = UInt8(32 + (x * 13 + y * 29) % 160)
            }
        }
        return pixels
    }

    /// Interleaved RGBX with the fourth byte unused.
    static func opaque(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 23 + y * 3) & 0xFF)
                pixels[offset + 1] = UInt8((x * 91 + y * 17) & 0xFF)
                pixels[offset + 2] = UInt8((x * 7 + y * 53) & 0xFF)
                pixels[offset + 3] = 0
            }
        }
        return pixels
    }
}

/// One directly constructed decoded source, named by what makes it useful.
///
/// A `CGImage` is not `Sendable`, so an arm carries this descriptor and the image is built
/// inside the property body.
private enum MetadataSourceKind: Hashable, Sendable {
    /// Display P3 with a genuinely varying alpha channel: the colour field's two
    /// non-refusing actions differ on it, and so do the alpha field's.
    case wideGamutWithAlpha
    /// Display P3, no alpha channel.
    case wideGamutOpaque
    /// One grayscale channel, whose colorimetry cannot be relabelled as RGB — so
    /// `assign-working-space-without-conversion` refuses it while converting succeeds.
    case grayscale

    func image(width: Int, height: Int) -> CGImage {
        switch self {
        case .wideGamutWithAlpha:
            return SourceImageFixture.interleaved32(
                width: width,
                height: height,
                pixels: MetadataSourcePixels.varyingAlpha(width: width, height: height),
                space: SourceImageFixture.displayP3,
                alpha: .last
            )
        case .wideGamutOpaque:
            return SourceImageFixture.interleaved32(
                width: width,
                height: height,
                pixels: MetadataSourcePixels.opaque(width: width, height: height),
                space: SourceImageFixture.displayP3,
                alpha: .noneSkipLast
            )
        case .grayscale:
            return SourceImageFixture.grayscale(width: width, height: height)
        }
    }

    var label: String {
        switch self {
        case .wideGamutWithAlpha: "display-p3 source with varying alpha"
        case .wideGamutOpaque: "opaque display-p3 source"
        case .grayscale: "grayscale source"
        }
    }
}

// MARK: - Containers

/// How one candidate container is produced.
private enum MetadataContainerKind: Hashable, Sendable {
    /// A JPEG declaring exactly one TIFF/EXIF orientation value.
    case exifJPEG(orientation: Int)
    /// A JPEG whose top-level and TIFF orientation declarations disagree, so it names two
    /// orientations and no single one can be applied.
    case conflictingJPEG(topLevel: Int, tiff: Int)
    /// An Image I/O PNG written from an opaque source with no properties.
    case encodedPNG
    /// An Image I/O PNG written from an alpha-carrying source.
    case encodedPNGWithAlpha
    /// An Image I/O PNG written from a Display P3 source, so the decode carries wide-gamut
    /// colorimetry and the two profile actions are distinguishable on a real container.
    case encodedWideGamutPNG
    /// A hand-assembled PNG with no colour-management chunk of any kind.
    case rawPNGWithoutColorChunks
    /// A hand-assembled PNG carrying an `sRGB` chunk, so Image I/O reports a profile name.
    case rawPNGWithSRGBChunk
    /// A hand-assembled RGBA PNG with no colour chunk.
    case rawPNGWithAlpha
    /// A hand-assembled single-channel PNG.
    case rawPNGGrayscale

    func bytes(width: Int, height: Int) -> [UInt8]? {
        switch self {
        case .exifJPEG(let value):
            return DeclaringImageFixture.jpeg(orientation: value, width: width, height: height)
        case .conflictingJPEG(let topLevel, let tiff):
            return DeclaringImageFixture.encode(
                EncodedImageFixture.gradient(width: width, height: height),
                as: .jpeg,
                properties: [
                    kCGImagePropertyOrientation: topLevel,
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: tiff],
                ]
            )
        case .encodedPNG:
            return EncodedImageFixture.encode(
                EncodedImageFixture.gradient(width: width, height: height),
                as: .png
            )
        case .encodedPNGWithAlpha:
            return DeclaringImageFixture.encode(
                MetadataSourceKind.wideGamutWithAlpha.image(width: width, height: height),
                as: .png,
                properties: [:]
            )
        case .encodedWideGamutPNG:
            return DeclaringImageFixture.encode(
                MetadataSourceKind.wideGamutOpaque.image(width: width, height: height),
                as: .png,
                properties: [:]
            )
        case .rawPNGWithoutColorChunks:
            return RawPNG.withoutColorChunks(width: width, height: height)
        case .rawPNGWithSRGBChunk:
            return RawPNG.withSRGBChunk(width: width, height: height)
        case .rawPNGWithAlpha:
            return RawPNG.withoutColorChunks(
                width: width,
                height: height,
                colorType: .truecolorAlpha
            )
        case .rawPNGGrayscale:
            return RawPNG.withoutColorChunks(
                width: width,
                height: height,
                colorType: .grayscale
            )
        }
    }

    var label: String {
        switch self {
        case .exifJPEG(let value): "jpeg declaring orientation \(value)"
        case .conflictingJPEG(let top, let tiff): "jpeg declaring \(top) and \(tiff)"
        case .encodedPNG: "encoded png"
        case .encodedPNGWithAlpha: "encoded png with alpha"
        case .encodedWideGamutPNG: "encoded display-p3 png"
        case .rawPNGWithoutColorChunks: "hand-assembled png with no colour chunk"
        case .rawPNGWithSRGBChunk: "hand-assembled png with an srgb chunk"
        case .rawPNGWithAlpha: "hand-assembled rgba png"
        case .rawPNGGrayscale: "hand-assembled grayscale png"
        }
    }
}

// MARK: - Arms

/// One way a generated case obtains an observed metadata triple.
private enum MetadataArmSource: Hashable, Sendable {
    /// Real encoded bytes. The triple is measured from the container on every case.
    case container(MetadataContainerKind)
    /// A triple stated directly over a real decoded image, for the states no encoder on
    /// this host expresses.
    case statedOver(MetadataSourceKind)

    var label: String {
        switch self {
        case .container(let kind): "container: \(kind.label)"
        case .statedOver(let source): "stated over \(source.label)"
        }
    }
}

/// One arm: a source, and the observed metadata triple it presents.
private struct MetadataArm: Hashable, Sendable {
    let source: MetadataArmSource

    /// The triple this arm presents.
    ///
    /// For a container arm this is what ``ImageMetadataInspector`` observed during
    /// discovery, and every case re-measures it before asserting anything. For a stated
    /// arm it is the triple the case hands the transform.
    let observed: ObservedImageMetadata

    /// The single declared orientation, present only in the valid state.
    let declaredOrientation: ExifOrientation?

    var isMeasuredFromAContainer: Bool {
        if case .container = source { return true }
        return false
    }

    /// The state this arm presents for `field`.
    func state(of field: MetadataField) -> ImageMetadataState {
        switch field {
        case .orientation: observed.orientation
        case .colorProfile: observed.colorProfile
        case .alpha: observed.alpha
        }
    }

    var label: String {
        """
        \(source.label) → orientation \(observed.orientation.rawValue)\
        \(declaredOrientation.map { "/\($0.rawValue)" } ?? ""), \
        profile \(observed.colorProfile.rawValue), alpha \(observed.alpha.rawValue)
        """
    }
}

/// The metadata states this host can actually express, discovered rather than assumed.
///
/// A container candidate is kept only when its bytes really decode to the probe's own
/// dimensions and the real inspector really observes a triple for them. What that triple
/// is, is read off the container rather than declared in advance: Image I/O normalizes
/// some declarations while writing, and asserting an intent the host does not honour would
/// make an arm pass while measuring something else. Candidates whose bytes or decode this
/// host cannot produce are dropped and reported, never replaced by a stand-in.
///
/// The stated arms cover the remaining `(field, state)` pairs. They are not a substitute
/// for a container: they are the only way to reach the branches
/// ``ImageMetadataInspector`` documents as unreachable from an encoder, and Requirement
/// 3.7 covers those states too.
///
/// Computed once. Encoding and decoding probes per generated case to answer the same
/// question 100 times would put host capability detection inside the measured property.
private enum MetadataCatalog {
    /// Probe dimensions. Deliberately non-square, so a candidate that silently exchanged
    /// the axes while writing would fail discovery rather than be admitted.
    private static let probeWidth = 14
    private static let probeHeight = 9

    /// Every candidate container that was tried.
    static let containerCandidates: [MetadataContainerKind] = {
        var candidates: [MetadataContainerKind] = (1...8).map { .exifJPEG(orientation: $0) }
        candidates += [
            // Integers outside 1 through 8 name no transform. Image I/O's own encoder
            // normalizes them while writing, so these are expected to be dropped on this
            // host; they are listed so the catalogue states what was tried.
            .exifJPEG(orientation: 0),
            .exifJPEG(orientation: 9),
            .conflictingJPEG(topLevel: 1, tiff: 6),
            .conflictingJPEG(topLevel: 3, tiff: 8),
            .encodedPNG,
            .encodedPNGWithAlpha,
            .encodedWideGamutPNG,
            .rawPNGWithoutColorChunks,
            .rawPNGWithSRGBChunk,
            .rawPNGWithAlpha,
            .rawPNGGrayscale,
        ]
        return candidates
    }()

    /// The container arms this host really produces, with the triple each really presents.
    static let containerArms: [MetadataArm] = containerCandidates.compactMap { kind in
        guard let bytes = kind.bytes(width: probeWidth, height: probeHeight),
              let declarations = DeclaringImageFixture.declarations(of: bytes),
              let decoded = DeclaringImageFixture.decode(bytes),
              decoded.width == probeWidth,
              decoded.height == probeHeight
        else {
            return nil
        }
        let observed = ImageMetadataInspector.observe(properties: declarations, image: decoded)
        return MetadataArm(
            source: .container(kind),
            observed: observed,
            declaredOrientation: observed.declaredOrientation
        )
    }

    /// The candidates this host could not express, reported by the witness.
    static let droppedContainerCandidates: [MetadataContainerKind] = {
        let expressed = Set(
            containerArms.compactMap { arm -> MetadataContainerKind? in
                guard case .container(let kind) = arm.source else { return nil }
                return kind
            }
        )
        return containerCandidates.filter { !expressed.contains($0) }
    }()

    /// The `(field, state)` pairs a real container on this host presents.
    static let statesFromContainers: [MetadataField: Set<ImageMetadataState>] = {
        var states: [MetadataField: Set<ImageMetadataState>] = [:]
        for field in MetadataField.allCases {
            states[field] = Set(containerArms.map { $0.state(of: field) })
        }
        return states
    }()

    /// One stated arm per `(field, state)` pair, so all twelve are covered whatever the
    /// host's encoders do, reduced to the distinct arms that produces.
    ///
    /// The twelve pairs do not yield twelve distinct arms. Each of the three sweeps holds the
    /// two fields it is not about at a state a container also presents, and for the sweeps
    /// over `orientation`, `colorProfile`, and `alpha` those hold-values coincide at exactly
    /// one point: the triple `(orientation: absent, colorProfile: valid, alpha: valid)` over
    /// the alpha-carrying source is what the orientation sweep's `absent` case, the profile
    /// sweep's `valid` case, and the alpha sweep's `valid` case all reduce to. Those three are
    /// the same ``MetadataArm`` value, so eleven distinct arms cover the twelve pairs.
    ///
    /// They are deduplicated rather than left in. Three copies of one arm would weight it
    /// three times in the draw while adding no state the other two do not already present,
    /// and — because the witness keys an arm by its label — would make full arm coverage
    /// unreachable and any assertion of it unsatisfiable. First occurrence wins, so the order
    /// stays fixed and the draw stays reproducible.
    ///
    /// The two fields a stated arm is not about are held at a state a container also
    /// presents, so the arm varies in one place at a time. The alpha state and the source's
    /// alpha layout are kept consistent with what ``ImageMetadataInspector/alphaState``
    /// pairs them with, so no arm states a triple the inspector could never produce.
    static let statedArms: [MetadataArm] = {
        var arms: [MetadataArm] = []
        for state in ImageMetadataState.allCases {
            // A transposing declaration in the valid state, so applying it is observably
            // different from ignoring it.
            let declared: ExifOrientation? = state == .valid ? .rightTop : nil
            arms.append(
                MetadataArm(
                    source: .statedOver(.wideGamutWithAlpha),
                    observed: ObservedImageMetadata(
                        orientation: state,
                        declaredOrientation: declared,
                        colorProfile: .valid,
                        alpha: .valid,
                        carriesAlphaChannel: true
                    ),
                    declaredOrientation: declared
                )
            )
        }
        for state in ImageMetadataState.allCases {
            arms.append(
                MetadataArm(
                    source: .statedOver(.wideGamutWithAlpha),
                    observed: ObservedImageMetadata(
                        orientation: .absent,
                        declaredOrientation: nil,
                        colorProfile: state,
                        alpha: .valid,
                        carriesAlphaChannel: true
                    ),
                    declaredOrientation: nil
                )
            )
        }
        for state in ImageMetadataState.allCases {
            // `valid` is the only alpha state the inspector pairs with a decoded alpha
            // channel; the other three are paired with none, so those arms use an opaque
            // source and their composite/discard results agree by construction. That is
            // the renderer's own documented equivalence, not a gap: the discrimination the
            // alpha field needs comes from the alpha-carrying arms, and the witness counts
            // them.
            let carriesAlpha = state == .valid
            arms.append(
                MetadataArm(
                    source: .statedOver(carriesAlpha ? .wideGamutWithAlpha : .wideGamutOpaque),
                    observed: ObservedImageMetadata(
                        orientation: .absent,
                        declaredOrientation: nil,
                        colorProfile: .valid,
                        alpha: state,
                        carriesAlphaChannel: carriesAlpha
                    ),
                    declaredOrientation: nil
                )
            )
        }
        // One grayscale arm, so the colour field's assignment action has an input it
        // genuinely cannot be applied to and the two profile actions differ by outcome
        // rather than only by samples.
        arms.append(
            MetadataArm(
                source: .statedOver(.grayscale),
                observed: ObservedImageMetadata(
                    orientation: .absent,
                    declaredOrientation: nil,
                    colorProfile: .valid,
                    alpha: .absent,
                    carriesAlphaChannel: false
                ),
                declaredOrientation: nil
            )
        )
        var seen = Set<MetadataArm>()
        return arms.filter { seen.insert($0).inserted }
    }()

    /// Everything the generator draws from.
    static let arms: [MetadataArm] = containerArms + statedArms

    /// The states the whole catalogue presents per field, which is what the witness holds
    /// the generator to. All four for every field, by construction of the stated arms.
    static let statesPerField: [MetadataField: Set<ImageMetadataState>] = {
        var states: [MetadataField: Set<ImageMetadataState>] = [:]
        for field in MetadataField.allCases {
            states[field] = Set(arms.map { $0.state(of: field) })
        }
        return states
    }()
}

// MARK: - Rule mutations

/// How the activation half breaks a total map.
///
/// Removal is the gap the requirement is about. The two duplications are the other way a
/// map fails to bind a state *exactly once*, and they matter because a dictionary lookup
/// over the same data resolves them silently: the same signed bytes would then read as two
/// different contracts depending on which entry won.
private enum RuleMutation: String, Hashable, Sendable, CaseIterable {
    case removeEntry = "remove-entry"
    case duplicateWithDifferentAction = "duplicate-with-different-action"
    case duplicateWithSameAction = "duplicate-with-same-action"

    /// The schema violation this mutation must produce for `state`.
    func expectedSchemaError(for state: ImageMetadataState) -> ArtifactSchemaError {
        switch self {
        case .removeEntry:
            .missingRequiredEntries(field: metadataRuleField, keys: [state.rawValue])
        case .duplicateWithDifferentAction, .duplicateWithSameAction:
            .duplicateEntry(field: metadataRuleField, key: state.rawValue)
        }
    }
}

// MARK: - Generated shape

/// One generated case, as plain data.
///
/// The generator produces data only. Images, artifacts, and payloads are built inside the
/// property body, where a construction that unexpectedly fails is recorded as an issue
/// rather than thrown: `propertyCheck` discards an error thrown by its body, so a refusal
/// that escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// Every dimension the assertions depend on is generated:
///
///   * the arm, over every container this host can express and every stated `(field,
///     state)` pair, so selection is checked against all four states of all three fields;
///   * width and height independently, so no container is square or a fixed size by
///     construction and a transposing declaration is observable;
///   * the selected and foil action of each of the three fields independently, over every
///     member of every action list, so the map's other entries always name something
///     different from the observed state's entry;
///   * which of the twelve `(field, state)` pairs the activation half attacks;
///   * how it attacks it;
///   * every synthetic identifier and the composite background colour, from ``seed``.
///
/// ``MetadataVariationWitness`` checks after the run that this actually happened.
private struct MetadataShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier and the composite background, so the whole
    /// reference set varies together without a cross-reference table.
    ///
    /// Used only in identifier strings and in a background colour. No schema version is
    /// derived from it: a version whose every component can be zero can name the `0.0.0`
    /// development stand-in, which the artifact schema rejects, and the refusal would
    /// surface as a construction failure in an unrelated arm.
    let seed: Int

    let armIndex: Int
    let width: Int
    let height: Int

    /// Packed `(selected, foil)` choice per field.
    ///
    /// Decoded as `selected = raw / 2` over a three-member list and
    /// `foil = (selected + raw % 2 + 1) % 3`, so the foil is never the selected action and
    /// every ordered distinct pair is reachable.
    let orientationChoice: Int
    let colorProfileChoice: Int
    let alphaChoice: Int

    let activationTargetIndex: Int
    let activationMutationIndex: Int

    var arm: MetadataArm {
        MetadataCatalog.arms[armIndex % max(MetadataCatalog.arms.count, 1)]
    }

    var mutation: RuleMutation {
        RuleMutation.allCases[activationMutationIndex % RuleMutation.allCases.count]
    }

    /// The `(field, state)` pair the activation half removes or duplicates.
    var activationTarget: (field: MetadataField, state: ImageMetadataState) {
        let pairs = MetadataField.allCases.flatMap { field in
            ImageMetadataState.allCases.map { (field: field, state: $0) }
        }
        return pairs[activationTargetIndex % pairs.count]
    }

    // MARK: Selected and foil actions

    private func indices(_ raw: Int, count: Int) -> (selected: Int, foil: Int) {
        let selected = (raw / 2) % count
        let foil = (selected + (raw % 2) + 1) % count
        return (selected, foil)
    }

    var orientationActions: (selected: OrientationAction, foil: OrientationAction) {
        let list = MetadataActionCatalogue.orientation
        let picked = indices(orientationChoice, count: list.count)
        return (list[picked.selected], list[picked.foil])
    }

    var colorProfileActions: (selected: ColorProfileAction, foil: ColorProfileAction) {
        let list = MetadataActionCatalogue.colorProfile
        let picked = indices(colorProfileChoice, count: list.count)
        return (list[picked.selected], list[picked.foil])
    }

    var alphaActions: (selected: AlphaAction, foil: AlphaAction) {
        let list = MetadataActionCatalogue.alpha(seed: seed)
        let picked = indices(alphaChoice, count: list.count)
        return (list[picked.selected], list[picked.foil])
    }

    var description: String {
        """
        seed \(seed), arm \(arm.label), \(width)x\(height), \
        orientation \(orientationActions.selected.rawValue) over \
        \(orientationActions.foil.rawValue), \
        profile \(colorProfileActions.selected.rawValue) over \
        \(colorProfileActions.foil.rawValue), \
        alpha \(alphaActions.selected) over \(alphaActions.foil), \
        activation \(mutation.rawValue) of \(activationTarget.field.rawValue)/\
        \(activationTarget.state.rawValue)
        """
    }

    // MARK: Generators

    static var generator: Generator<MetadataShape, AnySequence<Any>> {
        zip(
            Gen.int(in: 0...9_999),
            Gen.int(in: 0...199),
            Gen.int(in: 8...40),
            Gen.int(in: 8...40),
            Gen.int(in: 0...5),
            Gen.int(in: 0...5),
            Gen.int(in: 0...5),
            Gen.int(in: 0...199),
            Gen.int(in: 0...199)
        )
        .map { raw in
            MetadataShape(
                seed: raw.0,
                armIndex: raw.1,
                width: raw.2,
                height: raw.3,
                orientationChoice: raw.4,
                colorProfileChoice: raw.5,
                alphaChoice: raw.6,
                activationTargetIndex: raw.7,
                activationMutationIndex: raw.8
            )
        }
        .eraseToAny()
    }
}

// MARK: - Observable outcomes

/// What applying a contract produced, reduced to a comparable value.
///
/// A refusal compares only by the fault, which is the whole of what Requirement 3.11
/// admits: one `preprocessing-error` with no partial result. A rendered surface compares by
/// its dimensions and every byte, because the actions that differ do so by permuting
/// coordinates or by changing samples and nothing weaker would notice.
private enum RenderOutcome: Equatable, CustomStringConvertible {
    case refused(AnalysisFault)
    case rendered(width: Int, height: Int, bytes: [UInt8])

    var description: String {
        switch self {
        case .refused(let fault): "refused(\(fault))"
        case .rendered(let width, let height, let bytes):
            "rendered(\(width)x\(height), \(bytes.count) bytes)"
        }
    }
}

/// What the whole Preprocessor produced, reduced to a comparable value.
private enum PrepareOutcome: Equatable, CustomStringConvertible {
    case refused(AnalysisFault)
    case prepared(edge: Int, bytes: [UInt8])

    var description: String {
        switch self {
        case .refused(let fault): "refused(\(fault))"
        case .prepared(let edge, let bytes): "prepared(\(edge), \(bytes.count) bytes)"
        }
    }
}

/// Why the harness could not get far enough to observe an outcome at all.
///
/// Deliberately a different channel from ``PrepareOutcome/refused``. A refusal is the
/// Preprocessor applying a contract action that says reject, which is a property
/// observation and one of the outcomes Requirement 3.11 admits. This type is the test's
/// own setup failing — a fixture that would not build, a real container that would not
/// validate — which is never a property result and must be recorded as an issue instead of
/// compared against anything.
///
/// It exists because `Result` requires its failure type to be an `Error`, and it is
/// `CustomStringConvertible` so a caller can interpolate it straight into `Issue.record`.
private struct MetadataHarnessFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - The pipeline under test

/// The real validator and the real preprocessor over one session's stores.
///
/// Built per run so two runs never share a store, and so the identifiers a failure reports
/// name the case that produced it.
private struct MetadataPipeline {
    let store = InMemoryEncodedAssetStore()
    let decodedImages = DecodedImageStore()
    let modelInputs = PreparedModelInputStore()
    let quality = InputQualityLedger()
    let contract: PreprocessingContract
    let budget: ResourceBudget
    private let validator: ImageIOInputValidator
    private let preprocessor: ContractImagePreprocessor

    init(contract: PreprocessingContract, budget: ResourceBudget) {
        self.contract = contract
        self.budget = budget
        self.validator = ImageIOInputValidator(
            encodedAssets: store,
            decodedImages: decodedImages,
            quality: quality
        )
        self.preprocessor = ContractImagePreprocessor(
            encodedAssets: store,
            decodedImages: decodedImages,
            modelInputs: modelInputs
        )
    }

    /// Validates then prepares `bytes`. Returns rather than throws, so the caller records
    /// an issue instead of letting a fault escape the property body.
    func prepare(
        _ bytes: [UInt8],
        sessionID: AnalysisSessionID
    ) async -> Result<PrepareOutcome, MetadataHarnessFailure> {
        let asset: ImportedEncodedAsset
        do {
            asset = try await IngestFixture.asset(
                bytes: bytes,
                in: store,
                sessionID: sessionID
            )
        } catch {
            return .failure(MetadataHarnessFailure("building the session failed: \(error)"))
        }
        let validated: ValidatedImage
        do {
            validated = try await validator.validate(asset, contract: contract, budget: budget)
        } catch {
            return .failure(
                MetadataHarnessFailure("a real supported container must validate; got \(error)")
            )
        }
        do {
            let input = try await preprocessor.prepare(
                validated,
                contract: contract,
                budget: budget
            )
            guard let prepared = await modelInputs.preparedInput(for: input.buffer) else {
                return .failure(
                    MetadataHarnessFailure("a prepared input must be retained behind its token")
                )
            }
            return .success(.prepared(edge: prepared.edge, bytes: prepared.bytes))
        } catch {
            return .success(.refused(error))
        }
    }
}

// MARK: - Scenario

/// One generated shape and the two halves it checks.
private struct MetadataScenario {
    let shape: MetadataShape
    let witness: MetadataVariationWitness

    // MARK: - Contracts

    /// The generated contract: each field binds the selected action to the state this arm
    /// presents and the foil action to the other three.
    ///
    /// Three of the four entries of every map name something else, so any rule that read
    /// the map other than at the observed state would produce a different result.
    private func generatedContract(
        _ observed: ObservedImageMetadata,
        id: String
    ) -> PreprocessingContract {
        PreprocessingFixture.contract(
            id: id,
            orientationRules: PreprocessingFixture.rules(
                Self.perState(
                    selected: shape.orientationActions.selected,
                    foil: shape.orientationActions.foil,
                    observed: observed.orientation
                )
            ),
            colorProfileRules: PreprocessingFixture.rules(
                Self.perState(
                    selected: shape.colorProfileActions.selected,
                    foil: shape.colorProfileActions.foil,
                    observed: observed.colorProfile
                )
            ),
            alphaRules: PreprocessingFixture.rules(
                Self.perState(
                    selected: shape.alphaActions.selected,
                    foil: shape.alphaActions.foil,
                    observed: observed.alpha
                )
            )
        )
    }

    /// A contract that names only the selected actions, for every state.
    ///
    /// The reference the generated contract is compared against. It cannot have selected
    /// anything else, so byte equality between the two is a proof that the generated
    /// contract's other three entries had no effect.
    private func referenceContract(id: String) -> PreprocessingContract {
        PreprocessingFixture.contract(
            id: id,
            orientation: shape.orientationActions.selected,
            colorProfile: shape.colorProfileActions.selected,
            alpha: shape.alphaActions.selected
        )
    }

    /// The reference contract with one field replaced by that field's foil action.
    ///
    /// The other half of the comparison: where this produces a different result from the
    /// reference, the generated contract has to match the reference and not this. That is
    /// what rules out a nearest-match or first-entry rule that happened to agree.
    private func foilContract(_ field: MetadataField, id: String) -> PreprocessingContract {
        PreprocessingFixture.contract(
            id: id,
            orientation: field == .orientation
                ? shape.orientationActions.foil
                : shape.orientationActions.selected,
            colorProfile: field == .colorProfile
                ? shape.colorProfileActions.foil
                : shape.colorProfileActions.selected,
            alpha: field == .alpha ? shape.alphaActions.foil : shape.alphaActions.selected
        )
    }

    private static func perState<Action: Hashable & Codable & Sendable>(
        selected: Action,
        foil: Action,
        observed: ImageMetadataState
    ) -> [ImageMetadataState: Action] {
        Dictionary(
            uniqueKeysWithValues: ImageMetadataState.allCases.map {
                ($0, $0 == observed ? selected : foil)
            }
        )
    }

    // MARK: - Activation

    /// Requirement 3.7: a map that does not bind a state exactly once is refused, at every
    /// layer a contract can arrive through, and the refusal names that state.
    ///
    /// The positive control on the untouched map runs first in every layer. Without it a
    /// build where nothing decodes at all would satisfy every assertion below.
    func checkAnIncompleteMapIsRefusedAtActivation() {
        let target = shape.activationTarget
        // The activation half does not need an image, so it is checked against the arm's
        // triple purely to keep the map under test the same one selection is checked
        // against. Which state is attacked is generated independently of which state the
        // arm presents, so every state's entry is removed on some case whether or not this
        // host can present it.
        let observed = shape.arm.observed

        switch target.field {
        case .orientation:
            let actions = shape.orientationActions
            let perState = Self.perState(
                selected: actions.selected,
                foil: actions.foil,
                observed: observed.orientation
            )
            checkLayers(
                field: target.field,
                perState: perState,
                target: target.state,
                alternative: perState[target.state] == actions.selected
                    ? actions.foil
                    : actions.selected
            )
        case .colorProfile:
            let actions = shape.colorProfileActions
            let perState = Self.perState(
                selected: actions.selected,
                foil: actions.foil,
                observed: observed.colorProfile
            )
            checkLayers(
                field: target.field,
                perState: perState,
                target: target.state,
                alternative: perState[target.state] == actions.selected
                    ? actions.foil
                    : actions.selected
            )
        case .alpha:
            let actions = shape.alphaActions
            let perState = Self.perState(
                selected: actions.selected,
                foil: actions.foil,
                observed: observed.alpha
            )
            checkLayers(
                field: target.field,
                perState: perState,
                target: target.state,
                alternative: perState[target.state] == actions.selected
                    ? actions.foil
                    : actions.selected
            )
        }
    }

    /// The three activation layers for one field's map.
    ///
    /// `alternative` is an action the target state's entry does not already name, so the
    /// "duplicate with a different action" mutation really names two different handlings
    /// for one state.
    private func checkLayers<Action: Hashable & Codable & Sendable>(
        field: MetadataField,
        perState: [ImageMetadataState: Action],
        target: ImageMetadataState,
        alternative: Action
    ) {
        let complete = ImageMetadataState.allCases.map {
            MetadataStateRules<Action>.Rule(state: $0, action: perState[$0]!)
        }
        #expect(
            perState[target] != alternative,
            "the duplicate must name a different action to be a contradiction [\(shape)]"
        )
        let mutated = Self.mutate(
            complete,
            target: target,
            mutation: shape.mutation,
            alternative: alternative
        )
        checkSchemaLayer(complete: complete, mutated: mutated, target: target)
        checkAdapterLayer(complete: complete, mutated: mutated, target: target)
        checkArtifactLayer(
            field: field,
            perState: perState,
            target: target,
            alternative: alternative
        )
    }

    /// The mutated rule list.
    private static func mutate<Action: Hashable & Codable & Sendable>(
        _ complete: [MetadataStateRules<Action>.Rule],
        target: ImageMetadataState,
        mutation: RuleMutation,
        alternative: Action
    ) -> [MetadataStateRules<Action>.Rule] {
        switch mutation {
        case .removeEntry:
            return complete.filter { $0.state != target }
        case .duplicateWithSameAction:
            return complete + complete.filter { $0.state == target }
        case .duplicateWithDifferentAction:
            return complete + [.init(state: target, action: alternative)]
        }
    }

    /// Layer one: the schema initializer, which is where a decoded artifact's map is
    /// validated.
    private func checkSchemaLayer<Action: Hashable & Codable & Sendable>(
        complete: [MetadataStateRules<Action>.Rule],
        mutated: [MetadataStateRules<Action>.Rule],
        target: ImageMetadataState
    ) {
        // Control. A total map constructs and answers for every state.
        do {
            let rules = try MetadataStateRules(rules: complete)
            for state in ImageMetadataState.allCases {
                #expect(
                    rules.action(for: state) == rules.rules.first { $0.state == state }?.action,
                    "the total map's accessor must return its own entry [\(shape)]"
                )
            }
        } catch {
            Issue.record("a total map must construct: \(error) [\(shape)]")
            return
        }
        // The refusal, named.
        do {
            _ = try MetadataStateRules(rules: mutated)
            Issue.record(
                """
                \(shape.mutation.rawValue) of \(target.rawValue) was accepted, \
                so something completed the map [\(shape)]
                """
            )
        } catch let error as ArtifactSchemaError {
            #expect(
                error == shape.mutation.expectedSchemaError(for: target),
                "the refusal must name \(target.rawValue); got \(error) [\(shape)]"
            )
            witness.recordSchemaRefusal()
        } catch {
            Issue.record("the schema layer refused with an unexpected error: \(error) [\(shape)]")
        }
    }

    /// Layer two: the adapter-side check the transform performs on the rule list it holds.
    ///
    /// Asserted through ``MetadataActionBinding`` rather than through the schema, because
    /// the rule list is a public array on a public type and the transform is the last place
    /// a gap could turn into a default. The refusal is checked to be *specific*: the target
    /// state resolves to nothing while every other state still resolves, so this is not a
    /// blanket rejection that would also fire on a total map.
    private func checkAdapterLayer<Action: Hashable & Codable & Sendable>(
        complete: [MetadataStateRules<Action>.Rule],
        mutated: [MetadataStateRules<Action>.Rule],
        target: ImageMetadataState
    ) {
        // Control.
        #expect(
            MetadataActionBinding.isTotal(complete),
            "a total rule list must be recognized as total [\(shape)]"
        )
        for state in ImageMetadataState.allCases {
            #expect(
                MetadataActionBinding.soleAction(for: state, in: complete)
                    == complete.first { $0.state == state }?.action,
                "a total rule list must bind \(state.rawValue) to its own entry [\(shape)]"
            )
        }
        // The refusal.
        #expect(
            MetadataActionBinding.isTotal(mutated) == false,
            "\(shape.mutation.rawValue) of \(target.rawValue) must not be total [\(shape)]"
        )
        #expect(
            MetadataActionBinding.soleAction(for: target, in: mutated) == nil,
            """
            \(target.rawValue) must resolve to no action after \
            \(shape.mutation.rawValue); taking the first entry would be the implicit \
            fallback the requirement forbids [\(shape)]
            """
        )
        for state in ImageMetadataState.allCases where state != target {
            #expect(
                MetadataActionBinding.soleAction(for: state, in: mutated) != nil,
                """
                \(state.rawValue) must still resolve, so the refusal is about \
                \(target.rawValue) rather than blanket [\(shape)]
                """
            )
        }
        witness.recordAdapterRefusal()
    }

    /// Layer three: the signed artifact bytes.
    ///
    /// The strongest form of the activation claim, because this is how a contract actually
    /// arrives: the payload is encoded from a valid contract, one entry is removed or
    /// duplicated in the encoded rule list, and the decode must refuse. The untouched
    /// payload is decoded first and compared against the contract it came from, so the
    /// refusal is attributable to the mutation and not to the encoding.
    private func checkArtifactLayer<Action: Hashable & Codable & Sendable>(
        field: MetadataField,
        perState: [ImageMetadataState: Action],
        target: ImageMetadataState,
        alternative: Action
    ) {
        let contract = PreprocessingFixture.contract(
            id: "preprocessing-p10-activation-\(shape.seed)",
            orientationRules: field == .orientation
                ? PreprocessingFixture.rules(perState as! [ImageMetadataState: OrientationAction])
                : nil,
            colorProfileRules: field == .colorProfile
                ? PreprocessingFixture.rules(perState as! [ImageMetadataState: ColorProfileAction])
                : nil,
            alphaRules: field == .alpha
                ? PreprocessingFixture.rules(perState as! [ImageMetadataState: AlphaAction])
                : nil
        )
        guard let payload = try? JSONEncoder().encode(contract) else {
            Issue.record("a schema-valid contract must encode [\(shape)]")
            return
        }
        // The measured premise: these bytes really are this contract.
        do {
            #expect(
                try JSONDecoder().decode(PreprocessingContract.self, from: payload) == contract,
                "the untouched payload must read back as the contract it came from [\(shape)]"
            )
        } catch {
            Issue.record("the untouched payload must decode: \(error) [\(shape)]")
            return
        }
        guard let alternativeRule = Self.ruleJSON(state: target, action: alternative) else {
            Issue.record("the alternative rule must serialize [\(shape)]")
            return
        }
        guard let mutated = Self.mutatedPayload(
            payload,
            key: field.rawValue,
            target: target,
            mutation: shape.mutation,
            alternative: alternativeRule
        ) else {
            Issue.record(
                """
                the payload carries no \(field.rawValue) entry for \(target.rawValue), \
                so nothing was mutated [\(shape)]
                """
            )
            return
        }
        do {
            let decoded = try JSONDecoder().decode(PreprocessingContract.self, from: mutated)
            Issue.record(
                """
                a payload whose \(field.rawValue) \(shape.mutation.rawValue) \
                targeted \(target.rawValue) decoded into \(decoded.id.rawValue), \
                so activation completed the map [\(shape)]
                """
            )
        } catch let error as DecodingError {
            checkDecodingErrorNames(target, error: error)
            witness.recordArtifactRefusal()
        } catch {
            Issue.record("the artifact layer refused with an unexpected error: \(error) [\(shape)]")
        }
    }

    /// The decode refusal carries the schema violation, so an audit can name the state.
    private func checkDecodingErrorNames(_ target: ImageMetadataState, error: DecodingError) {
        guard case .dataCorrupted(let context) = error else {
            Issue.record("a coverage violation must be reported as corrupted data [\(shape)]")
            return
        }
        guard let schema = context.underlyingError as? ArtifactSchemaError else {
            Issue.record(
                "the decode refusal must carry the schema violation; got \(context) [\(shape)]"
            )
            return
        }
        #expect(
            schema == shape.mutation.expectedSchemaError(for: target),
            "the decode refusal must name \(target.rawValue); got \(schema) [\(shape)]"
        )
    }

    // MARK: - Payload mutation

    /// One encoded rule, as a JSON object.
    ///
    /// Produced by encoding a one-element rule list, so the object is exactly the shape the
    /// contract's own encoder emits. Written out rather than assembled by hand because
    /// ``AlphaAction`` carries an associated value and its encoded form is not a bare
    /// string.
    private static func ruleJSON<Action: Hashable & Codable & Sendable>(
        state: ImageMetadataState,
        action: Action
    ) -> [String: Any]? {
        let rule = MetadataStateRules<Action>.Rule(state: state, action: action)
        guard let data = try? JSONEncoder().encode([rule]),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = array.first
        else {
            return nil
        }
        return object
    }

    /// The payload with `key`'s rule list mutated at `target`.
    ///
    /// Returns `nil` when the entry is not there to mutate, so a test cannot silently
    /// assert against an unmutated payload.
    private static func mutatedPayload(
        _ payload: Data,
        key: String,
        target: ImageMetadataState,
        mutation: RuleMutation,
        alternative: [String: Any]
    ) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              var rules = object[key] as? [[String: Any]],
              let index = rules.firstIndex(where: { $0["state"] as? String == target.rawValue })
        else {
            return nil
        }
        switch mutation {
        case .removeEntry:
            rules.remove(at: index)
        case .duplicateWithSameAction:
            rules.append(rules[index])
        case .duplicateWithDifferentAction:
            rules.append(alternative)
        }
        object[key] = rules
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - The observed metadata

    /// The triple this case's arm really presents.
    ///
    /// For a container arm the declarations are read back out of the container and the real
    /// inspector recomputes the triple at this case's own dimensions, so "the state the map
    /// is indexed by" is measured rather than named. For a stated arm the triple is the
    /// one the case hands the transform, which is the only way to reach the states no
    /// encoder on this host writes.
    func measureObservedMetadata() async -> ObservedImageMetadata? {
        guard !MetadataCatalog.arms.isEmpty else {
            Issue.record("the catalogue expresses no metadata state at all [\(shape)]")
            return nil
        }
        switch shape.arm.source {
        case .statedOver:
            return shape.arm.observed
        case .container(let kind):
            guard let bytes = kind.bytes(width: shape.width, height: shape.height) else {
                Issue.record("this host could not produce \(kind.label) [\(shape)]")
                return nil
            }
            guard let declarations = DeclaringImageFixture.declarations(of: bytes) else {
                Issue.record("Image I/O read no declarations from \(kind.label) [\(shape)]")
                return nil
            }
            guard let decoded = DeclaringImageFixture.decode(bytes) else {
                Issue.record("this host could not decode \(kind.label) [\(shape)]")
                return nil
            }
            let observed = ImageMetadataInspector.observe(
                properties: declarations,
                image: decoded
            )
            // The premise of every assertion that follows. Were the container to present a
            // different triple at these dimensions than at the probe's, the map would be
            // indexed by a state this case never named.
            guard observed == shape.arm.observed else {
                Issue.record(
                    """
                    \(kind.label) presented \(observed) at \(shape.width)x\(shape.height) \
                    rather than the discovered \(shape.arm.observed) [\(shape)]
                    """
                )
                return nil
            }
            return observed
        }
    }

    // MARK: - Selection: the bound action

    /// Requirement 3.8: the action is the entry for the observed state, and it changes when
    /// the observed state changes.
    ///
    /// The second half is what no implicit default can satisfy. A constant, a first-entry
    /// lookup, and a nearest-match rule all return the same action for two different
    /// observed states over this contract; the contract binds the selected action to one
    /// state and the foil to the other three, so the correct rule must return two different
    /// actions and every wrong one returns a single answer.
    func checkBindingReadsTheObservedStateAndNothingElse(_ observed: ObservedImageMetadata) {
        let contract = generatedContract(observed, id: "preprocessing-p10-bind-\(shape.seed)")
        guard let bound = bind(observed, contract: contract) else { return }

        #expect(
            bound.orientation == shape.orientationActions.selected,
            "the bound orientation action must be the observed state's entry [\(shape)]"
        )
        #expect(
            bound.colorProfile == shape.colorProfileActions.selected,
            "the bound profile action must be the observed state's entry [\(shape)]"
        )
        #expect(
            bound.alpha == shape.alphaActions.selected,
            "the bound alpha action must be the observed state's entry [\(shape)]"
        )
        // The action came from the list the contract names, which is the other half of "no
        // implicit default": not merely the right value, but a value the map contains.
        #expect(
            contract.orientationRules.rules.contains(where: { $0.action == bound.orientation }),
            "the bound orientation action must be one the map names [\(shape)]"
        )
        #expect(
            contract.colorProfileRules.rules.contains(where: { $0.action == bound.colorProfile }),
            "the bound profile action must be one the map names [\(shape)]"
        )
        #expect(
            contract.alphaRules.rules.contains(where: { $0.action == bound.alpha }),
            "the bound alpha action must be one the map names [\(shape)]"
        )
        witness.recordBoundActionCheck()

        // Every other state over the same contract binds the foil action. A lookup that did
        // not read the observed state could not produce both answers.
        for state in ImageMetadataState.allCases where state != observed.orientation {
            guard let other = bind(
                ObservedImageMetadata(
                    orientation: state,
                    declaredOrientation: shape.arm.declaredOrientation,
                    colorProfile: observed.colorProfile,
                    alpha: observed.alpha,
                    carriesAlphaChannel: observed.carriesAlphaChannel
                ),
                contract: contract
            ) else { continue }
            #expect(
                other.orientation == shape.orientationActions.foil,
                """
                observing \(state.rawValue) must bind that state's entry, not \
                \(observed.orientation.rawValue)'s [\(shape)]
                """
            )
            witness.recordStateSensitivityCheck()
        }
        for state in ImageMetadataState.allCases where state != observed.colorProfile {
            guard let other = bind(
                ObservedImageMetadata(
                    orientation: observed.orientation,
                    declaredOrientation: shape.arm.declaredOrientation,
                    colorProfile: state,
                    alpha: observed.alpha,
                    carriesAlphaChannel: observed.carriesAlphaChannel
                ),
                contract: contract
            ) else { continue }
            #expect(
                other.colorProfile == shape.colorProfileActions.foil,
                "observing profile \(state.rawValue) must bind that state's entry [\(shape)]"
            )
            witness.recordStateSensitivityCheck()
        }
        for state in ImageMetadataState.allCases where state != observed.alpha {
            guard let other = bind(
                ObservedImageMetadata(
                    orientation: observed.orientation,
                    declaredOrientation: shape.arm.declaredOrientation,
                    colorProfile: observed.colorProfile,
                    alpha: state,
                    carriesAlphaChannel: observed.carriesAlphaChannel
                ),
                contract: contract
            ) else { continue }
            #expect(
                other.alpha == shape.alphaActions.foil,
                "observing alpha \(state.rawValue) must bind that state's entry [\(shape)]"
            )
            witness.recordStateSensitivityCheck()
        }
    }

    private func bind(
        _ observed: ObservedImageMetadata,
        contract: PreprocessingContract
    ) -> BoundMetadataActions? {
        do {
            return try MetadataActionBinding.bind(observed, contract: contract)
        } catch {
            Issue.record("a total contract must bind every observed state: \(error) [\(shape)]")
            return nil
        }
    }

    // MARK: - Selection: what actually runs

    /// Requirement 3.8, behaviourally: applying the generated contract produces exactly
    /// what a contract naming only the selected actions produces, and — wherever a field's
    /// foil action is measurably different on this input — not what the foil produces.
    ///
    /// The equality is asserted on every case. The inequality is asserted only where the
    /// two actions are measured to differ, because several action pairs are provably
    /// equivalent on a given input: compositing over any background and discarding alpha
    /// agree exactly on an image whose alpha channel is opaque, and converting into the
    /// source's own space is the identity. Asserting a difference there would be asserting
    /// something false. ``MetadataVariationWitness`` requires a floor of really
    /// discriminating cases per field, so the inequality half cannot quietly stop happening.
    func checkRenderingFollowsTheObservedStatesEntry(_ observed: ObservedImageMetadata) async {
        let source = self.source()
        let budget = ResourceFixture.budget(id: "budget-p10-render-\(shape.seed)")
        let decoded = DecodedImageFixture.of(source, sessionID: session("render"))

        let generated = render(
            decoded,
            observed: observed,
            contract: generatedContract(observed, id: "preprocessing-p10-generated-\(shape.seed)"),
            budget: budget
        )
        let reference = render(
            decoded,
            observed: observed,
            contract: referenceContract(id: "preprocessing-p10-reference-\(shape.seed)"),
            budget: budget
        )
        #expect(
            generated == reference,
            """
            the generated contract binds the selected action to \(observed) and a \
            different action to every other state; it produced \(generated) where a \
            contract naming only the selected actions produced \(reference) [\(shape)]
            """
        )
        witness.recordEquivalenceCheck()

        for field in MetadataField.allCases {
            let foil = render(
                decoded,
                observed: observed,
                contract: foilContract(field, id: "preprocessing-p10-foil-\(shape.seed)"),
                budget: budget
            )
            guard foil != reference else {
                // The two actions agree on this input, so this field cannot discriminate
                // here. Recorded rather than asserted, and the witness holds the run to a
                // floor of cases where it can.
                continue
            }
            #expect(
                generated != foil,
                """
                \(field.rawValue)'s foil action produces \(foil) on this input, and the \
                generated contract binds it to the three states this input does not \
                present; producing it anyway would mean selection read the wrong entry \
                [\(shape)]
                """
            )
            witness.recordDiscrimination(field)
        }
    }

    /// The same claim through the whole Preprocessor, on the cases whose state was measured
    /// from a real container.
    ///
    /// This is what connects the two halves. The renderer comparison above is handed an
    /// observation; here the adapter reads the retained encoded bytes itself, observes the
    /// declarations with the real inspector, and indexes the map with whatever it found.
    /// A build that passed a constant observation into the renderer would satisfy every
    /// assertion above and fail here.
    func checkTheWholePreprocessorFollowsTheSameEntry(_ observed: ObservedImageMetadata) async {
        guard case .container(let kind) = shape.arm.source else { return }
        guard let bytes = kind.bytes(width: shape.width, height: shape.height) else {
            Issue.record("this host could not produce \(kind.label) [\(shape)]")
            return
        }
        let generatedPipeline = MetadataPipeline(
            contract: generatedContract(
                observed,
                id: "preprocessing-p10-endtoend-generated-\(shape.seed)"
            ),
            budget: ResourceFixture.budget(id: "budget-p10-endtoend-a-\(shape.seed)")
        )
        let referencePipeline = MetadataPipeline(
            contract: referenceContract(
                id: "preprocessing-p10-endtoend-reference-\(shape.seed)"
            ),
            budget: ResourceFixture.budget(id: "budget-p10-endtoend-b-\(shape.seed)")
        )
        let generated = await generatedPipeline.prepare(bytes, sessionID: session("endtoend-a"))
        let reference = await referencePipeline.prepare(bytes, sessionID: session("endtoend-b"))
        guard case .success(let generatedOutcome) = generated else {
            if case .failure(let reason) = generated { Issue.record("\(reason) [\(shape)]") }
            return
        }
        guard case .success(let referenceOutcome) = reference else {
            if case .failure(let reason) = reference { Issue.record("\(reason) [\(shape)]") }
            return
        }
        #expect(
            generatedOutcome == referenceOutcome,
            """
            the whole Preprocessor produced \(generatedOutcome) under the generated \
            contract and \(referenceOutcome) under a contract naming only the selected \
            actions, so it did not index the map at the state it observed [\(shape)]
            """
        )
        // No prepared buffer survives a refusal, and exactly one survives a success. A
        // refusal that still handed pixels onward would be a partial result Requirement
        // 3.11 does not admit.
        let retained = await generatedPipeline.modelInputs.retainedInputCount
        switch generatedOutcome {
        case .refused:
            #expect(retained == 0, "a refused contract must prepare nothing [\(shape)]")
        case .prepared:
            #expect(retained == 1, "a completed preparation must retain one buffer [\(shape)]")
        }
        witness.recordEndToEndComparison()
    }

    // MARK: - Helpers

    private func source() -> CGImage {
        switch shape.arm.source {
        case .statedOver(let kind):
            return kind.image(width: shape.width, height: shape.height)
        case .container(let kind):
            // The real decode of the real container, so the renderer operates on the same
            // pixels and the same colour space the adapter would hand it.
            guard let bytes = kind.bytes(width: shape.width, height: shape.height),
                  let decoded = DeclaringImageFixture.decode(bytes)
            else {
                // Unreachable: `measureObservedMetadata` already produced both. Falling
                // back to a constructed source rather than trapping, because a trap here
                // would take the whole run down on a host capability question.
                return MetadataSourceKind.wideGamutOpaque.image(
                    width: shape.width,
                    height: shape.height
                )
            }
            return decoded
        }
    }

    private func render(
        _ decoded: DecodedImage,
        observed: ObservedImageMetadata,
        contract: PreprocessingContract,
        budget: ResourceBudget
    ) -> RenderOutcome {
        let renderer = WorkingSpaceRGBRenderer(contract: contract, budget: budget)
        do {
            let surface = try renderer.render(decoded, metadata: observed)
            return .rendered(
                width: surface.width,
                height: surface.height,
                bytes: surface.copyPackedBytes()
            )
        } catch {
            return .refused(error)
        }
    }

    private func session(_ suffix: String) -> AnalysisSessionID {
        guard let id = AnalysisSessionID("session-p10-\(shape.seed)-\(suffix)") else {
            preconditionFailure("a generated session identifier must be canonical")
        }
        return id
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator produced and what the body actually asserted.
///
/// It also proves the run happened at all. `propertyCheck` swallows an error thrown by its
/// body — the library runs the body under `try?` and moves to the next case — so a body that
/// failed before its first assertion would report a passing test in milliseconds with every
/// arm skipped. A witness that counts *outside* the body is the only thing that catches
/// that.
///
/// A case count alone is not enough, and in this file it would be actively misleading:
/// ``record(_:)`` is the body's first statement, so `cases` reaches its total even if
/// everything after it threw. Nor is a completion count enough on its own, because
/// `completed == cases` passes vacuously at zero. So each class of assertion carries its own
/// counter and each counter is compared against `cases` rather than against a constant. A
/// body that threw after recording would leave every one of them at zero against a `cases`
/// of four hundred, which fails loudly instead of passing quietly.
///
/// Coverage of the generated space is asserted exactly where the draw makes that sound and
/// as a floor where it does not, and the distinction is stated per assertion rather than
/// left to the reader. The claim the property would be vacuous without — that all four
/// states of all three fields are reachable at all — is additionally asserted against the
/// catalogue itself, which is a fact about its construction and does not depend on the draw.
private final class MetadataVariationWitness: @unchecked Sendable {
    private let lock = NSLock()

    // What was generated.
    private var arms = Set<MetadataArmKey>()
    private var containerArms = Set<MetadataArmKey>()
    private var statedArms = Set<MetadataArmKey>()
    private var observedStates: [MetadataField: Set<ImageMetadataState>] = [:]
    private var orientationActions = Set<OrientationAction>()
    private var colorProfileActions = Set<ColorProfileAction>()
    private var alphaActionLabels = Set<String>()
    private var activationFields = Set<MetadataField>()
    private var activationStates = Set<ImageMetadataState>()
    private var activationPairs = Set<String>()
    private var mutations = Set<RuleMutation>()
    private var dimensions = Set<Int>()
    private var nonSquareCases = 0
    private var seeds = Set<Int>()
    private var cases = 0

    // What was asserted.
    private var schemaRefusals = 0
    private var adapterRefusals = 0
    private var artifactRefusals = 0
    private var boundActionChecks = 0
    private var stateSensitivityChecks = 0
    private var equivalenceChecks = 0
    private var endToEndComparisons = 0
    private var discriminations: [MetadataField: Int] = [:]

    /// A hashable stand-in for an arm, so the witness holds no image-bearing value.
    private struct MetadataArmKey: Hashable {
        let label: String
    }

    func record(_ shape: MetadataShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        let arm = shape.arm
        let key = MetadataArmKey(label: arm.label)
        arms.insert(key)
        if arm.isMeasuredFromAContainer {
            containerArms.insert(key)
        } else {
            statedArms.insert(key)
        }
        for field in MetadataField.allCases {
            observedStates[field, default: []].insert(arm.state(of: field))
        }
        orientationActions.formUnion([
            shape.orientationActions.selected, shape.orientationActions.foil,
        ])
        colorProfileActions.formUnion([
            shape.colorProfileActions.selected, shape.colorProfileActions.foil,
        ])
        alphaActionLabels.formUnion([
            Self.label(shape.alphaActions.selected), Self.label(shape.alphaActions.foil),
        ])
        let target = shape.activationTarget
        activationFields.insert(target.field)
        activationStates.insert(target.state)
        activationPairs.insert("\(target.field.rawValue)/\(target.state.rawValue)")
        mutations.insert(shape.mutation)
        dimensions.formUnion([shape.width, shape.height])
        if shape.width != shape.height { nonSquareCases += 1 }
        seeds.insert(shape.seed)
    }

    /// The kind of an alpha action, without its generated background colour.
    ///
    /// The colour varies per seed, so counting whole values would report a hundred distinct
    /// actions and prove nothing about which handlings were exercised.
    private static func label(_ action: AlphaAction) -> String {
        switch action {
        case .discardAlphaChannel: "discard"
        case .compositeOverOpaqueBackground: "composite"
        case .rejectAsPreprocessingError: "reject"
        }
    }

    func recordSchemaRefusal() { increment { schemaRefusals += 1 } }
    func recordAdapterRefusal() { increment { adapterRefusals += 1 } }
    func recordArtifactRefusal() { increment { artifactRefusals += 1 } }
    func recordBoundActionCheck() { increment { boundActionChecks += 1 } }
    func recordStateSensitivityCheck() { increment { stateSensitivityChecks += 1 } }
    func recordEquivalenceCheck() { increment { equivalenceChecks += 1 } }
    func recordEndToEndComparison() { increment { endToEndComparisons += 1 } }

    func recordDiscrimination(_ field: MetadataField) {
        increment { discriminations[field, default: 0] += 1 }
    }

    private func increment(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")

        // What this host can express, reported so a reader knows which arms were measured
        // from real bytes and which states had to be stated directly.
        #expect(
            !MetadataCatalog.containerArms.isEmpty,
            "no candidate container was expressible on this host"
        )
        // The catalogue's own coverage, which is a fact about how it is built and not about
        // what was drawn. This is the assertion that makes the property total over
        // Requirement 3.7: every state of every field is reachable from some arm. If a
        // future edit removed a stated arm, this fails whatever the draw did.
        for field in MetadataField.allCases {
            #expect(
                MetadataCatalog.statesPerField[field] ?? [] == Set(ImageMetadataState.allCases),
                """
                the catalogue can present only \
                \((MetadataCatalog.statesPerField[field] ?? []).map(\.rawValue).sorted()) \
                for \(field.rawValue), so that field's map is not exercised at every state
                """
            )
        }
        // Arm coverage of the run. A floor of one missed arm rather than exact equality:
        // with the arms drawn uniformly this is all of them on nearly every run, and the one
        // permitted miss is there so a single unlucky draw is not a failure. The dropped
        // candidates are reported so a host that silently stopped expressing a container is
        // visible here rather than inferred.
        #expect(
            containerArms.count >= max(1, MetadataCatalog.containerArms.count - 1),
            """
            generated container arms: \(containerArms.map(\.label).sorted()); \
            expressible: \(MetadataCatalog.containerArms.count); \
            dropped candidates: \(MetadataCatalog.droppedContainerCandidates.map(\.label))
            """
        )
        #expect(
            statedArms.count >= max(1, MetadataCatalog.statedArms.count - 1),
            "generated stated arms: \(statedArms.count) of \(MetadataCatalog.statedArms.count)"
        )
        // All four states of all three fields were really presented as the observed state by
        // some case. Exact equality is sound at this case count: six of the twelve pairs come
        // from one arm each, and four hundred draws miss a given arm a few times in a hundred
        // thousand. It is asserted as well as the catalogue check above because a reachable
        // state that is never drawn is still a state selection was never checked against.
        for field in MetadataField.allCases {
            #expect(
                observedStates[field] ?? [] == Set(ImageMetadataState.allCases),
                """
                \(field.rawValue) presented \
                \((observedStates[field] ?? []).map(\.rawValue).sorted()); \
                from real containers: \
                \((MetadataCatalog.statesFromContainers[field] ?? []).map(\.rawValue).sorted())
                """
            )
        }
        // Every action of every field appeared, as a selected or a foil action, so no
        // handling went unexercised.
        #expect(
            orientationActions == Set(OrientationAction.allCases),
            "generated orientation actions: \(orientationActions.map(\.rawValue).sorted())"
        )
        #expect(
            colorProfileActions == Set(ColorProfileAction.allCases),
            "generated profile actions: \(colorProfileActions.map(\.rawValue).sorted())"
        )
        #expect(
            alphaActionLabels == ["composite", "discard", "reject"],
            "generated alpha actions: \(alphaActionLabels.sorted())"
        )
        // The activation half attacked every field and every state, and used every
        // mutation. Pair coverage is a count with headroom rather than set equality: with
        // twelve pairs drawn uniformly a missing pair is rare but not rare enough to make
        // an exact assertion worth a reader's attention.
        #expect(activationFields == Set(MetadataField.allCases), "activation fields")
        #expect(
            activationStates == Set(ImageMetadataState.allCases),
            "activation states: \(activationStates.map(\.rawValue).sorted())"
        )
        // Every one of the twelve entries was removed or duplicated on some case. Exact at
        // this case count: the target is drawn independently of the arm, so each pair is
        // drawn about a twelfth of the time and missing one over four hundred draws is
        // vanishingly unlikely.
        #expect(
            activationPairs.count == 12,
            "activation pairs: \(activationPairs.sorted()) — \(activationPairs.count) of 12"
        )
        #expect(
            mutations == Set(RuleMutation.allCases),
            "generated mutations: \(mutations.map(\.rawValue).sorted())"
        )
        #expect(dimensions.count >= 20, "generated dimensions: \(dimensions.count)")
        #expect(
            nonSquareCases >= cases / 2,
            "non-square cases: \(nonSquareCases) of \(cases)"
        )
        #expect(seeds.count >= cases / 2, "generated seeds: \(seeds.count) of \(cases)")

        // What was actually asserted. Each of these is a class of assertion the property
        // would be hollow without, and each is compared against `cases` rather than a
        // constant: these run unconditionally on every case, so anything less than `cases`
        // means a body returned early or threw, and zero against a non-zero `cases` is
        // exactly the silent-throw failure this witness exists to catch.
        #expect(
            schemaRefusals == cases,
            "schema-layer activation refusals: \(schemaRefusals) of \(cases)"
        )
        #expect(
            adapterRefusals == cases,
            "adapter-layer activation refusals: \(adapterRefusals) of \(cases)"
        )
        #expect(
            artifactRefusals == cases,
            "artifact-layer activation refusals: \(artifactRefusals) of \(cases)"
        )
        #expect(
            boundActionChecks == cases,
            "bound-action checks: \(boundActionChecks) of \(cases)"
        )
        // Three fields, three other states each, on every case.
        #expect(
            stateSensitivityChecks == cases * 9,
            "state-sensitivity checks: \(stateSensitivityChecks) of \(cases * 9)"
        )
        #expect(
            equivalenceChecks == cases,
            "selection equivalence checks: \(equivalenceChecks) of \(cases)"
        )
        // A floor rather than a comparison against `cases`: this one runs only on the cases
        // whose arm was a real container, which is a property of the draw. Roughly three
        // fifths of cases qualify on this host, so a tenth is a floor a real run clears
        // easily while still failing a run where the end-to-end half stopped happening.
        #expect(
            endToEndComparisons >= cases / 10,
            "whole-Preprocessor comparisons on measured containers: \(endToEndComparisons)"
        )
        // The inequality half really happened for each field. A floor, because whether two
        // actions differ is a fact about the drawn input rather than something the generator
        // controls; without it an input on which every action pair agreed would make the
        // whole comparison vacuous.
        for field in MetadataField.allCases {
            #expect(
                (discriminations[field] ?? 0) >= 10,
                "\(field.rawValue) discriminating cases: \(discriminations[field] ?? 0)"
            )
        }
    }
}
