import DefAIkeTestSupport
import Foundation
import PropertyBased
import Testing

@testable import DefAIkeDomain

// Design Property 1: coherent device allowlisting.
//
// The design states it as: for any candidate configuration and any set of validation
// records, the configuration is a member of the Release Approved iPhone Allowlist if and
// only if it is an iPhone running iOS 17 or later, is Apple Neural Engine-capable, every
// mandatory gate passes, and the device, OS, build, Model Bundle, fixture suite,
// validation plan, capability set, and implementation versions are identical across all
// records; any missing, failing, Mac-only, or version-mixed evidence excludes it, and an
// empty passing set blocks distribution.
//
// ## What "member" means here, and why it takes three layers
//
// "Membership" is not one predicate in this codebase, and collapsing it into one would
// assert the wrong thing. The domain deliberately separates being *listed* from being
// *approved* — ``ReleaseApprovedDeviceAllowlist`` accepts an entry whose gate evidence
// failed, and reports it as not distributable — so the property is quantified at each of
// the three layers where an exclusion actually happens:
//
//   * **unrepresentable.** An ineligible configuration or incoherent entry cannot be
//     built at all: iOS below 17, a non-Apple-Neural-Engine candidate, a candidate whose
//     application build disagrees with its own version tuple, a gate list that omits or
//     repeats a mandatory gate, and a passing gate claimed from anything but a physical
//     iPhone. These refuse with an ``ArtifactSchemaError``, which is the strongest
//     available form: there is no entry to exclude.
//   * **not satisfied.** A listed entry whose evidence is missing, failing, or recorded
//     off-device stays listed and reports the offending gates through
//     ``ApprovedDeviceConfiguration/unsatisfiedGates``, and the allowlist reports
//     ``ReleaseApprovedDeviceAllowlist/permitsDistribution`` false when no entry is
//     clean. Membership surviving matters: ``ValidatedAccessibilityGateMatrix`` derives
//     its required coverage from every entry regardless of that entry's own gate
//     outcomes, precisely so a configuration whose accessibility gate failed cannot drop
//     out of the required set and leave the remainder looking complete.
//   * **not admitted.** ``StartupPreflight`` is where a version-mixed entry is excluded,
//     because most of the tuple can only be compared against the release the running
//     build binds: an entry naming another Model Bundle, plan, manifest, capability set,
//     or implementation version is refused, an entry recorded under another application
//     build matches no device, and two entries under one manifest that disagree about a
//     fixture suite or plan are refused as mixed.
//
// ## The arms
//
//   * eligibility — iOS 17.0 is the inclusive floor, anything below it and any
//     non-Apple-Neural-Engine candidate is unrepresentable, and so is an entry whose two
//     application builds or whose capability set and implementation versions disagree;
//   * physical-device evidence — for every non-physical environment, a passing
//     applicable gate is unrepresentable, and the same environment recorded honestly
//     leaves the gate unsatisfied, with a physical-iPhone pass as the positive control;
//   * missing or failing evidence — a failed, unexecuted, dropped, repeated, or
//     rejected-inapplicability gate excludes, and the entry stays listed while it does;
//   * exact matching — lookup is on the exact hardware identifier, operating-system
//     version, and application build, and each sibling is found only by its own triple;
//   * empty passing set — an empty allowlist and an allowlist whose every entry fails
//     are both valid artifacts that permit no distribution, and both block ingest with
//     the whole-set finding rather than a per-device one;
//   * admission — a coherent generated release is admitted and everything it reports is
//     what the shape generated, unchanged;
//   * version tuple — every one of the seven encoded members of
//     ``ValidationVersionTuple`` is mutated alone and asserted to exclude, with the
//     member list read out of the encoded artifact so a member added to the tuple fails
//     the coverage assertion instead of being silently skipped.
//
// ``ReleaseArtifactSchemaTests`` and ``StartupPreflightTests`` pin each of these
// refusals at one field with one example. This file quantifies the same statement over
// generated shapes. The neighbouring properties belong to their own tasks: Property 31 is
// whether the accessibility and localization matrices fail closed, Property 32 is
// referential completeness of a Device Validation Plan and its recorded results, and
// Property 33 is whether the release readiness record as a whole is auditable.
//
// No value here is an approved device, configuration, build, bundle, plan, or decision.
// Every hardware identifier and version is synthetic and carries the generated seed, and
// the whole shape exists so that allowlisting can be asked to refuse it.

extension Tag {
    /// Design Property 1.
    ///
    /// Declared in this file rather than in a shared tag namespace: each design property
    /// gets one dedicated file, and a shared namespace would be a merge point between
    /// property files written independently of each other.
    @Tag static var property1DeviceAllowlisting: Self
}

@Suite(
    "Property 1: coherent device allowlisting",
    .tags(.property1DeviceAllowlisting)
)
struct DeviceAllowlistCoherencePropertyTests {
    /// Runs at the library default of 100 generated cases with shrinking, which is the
    /// minimum the design requires; `PropertyToolchainWiringTests` pins that default.
    /// Every generator is composed with `zip`, so the shrinkers compose.
    ///
    /// **Validates: Requirements 1.4, 13.2, 13.16, 13.18, 13.19, 13.20, 13.21, 13.22**
    @Test("Allowlist membership is exact and version-bound over generated gate records")
    func deviceAllowlistingIsCoherent() async {
        let witness = DeviceAllowlistVariationWitness()

        await propertyCheck(input: AllowlistShape.generator) { shape in
            witness.record(shape)
            let scenario = AllowlistScenario(shape: shape)

            scenario.checkOnlyEligibleConfigurationsAreRepresentable()
            scenario.checkOnlyPhysicalIPhoneEvidenceSatisfiesAGate()
            scenario.checkMissingOrFailingEvidenceExcludes()
            scenario.checkMatchingIsExactAndVersionBound()
            scenario.checkEmptyPassingSetPermitsNoDistribution()

            // The remaining arms need the release the running build binds, because that
            // is the only thing most of the version tuple can be compared against. It is
            // built once per case and the mutated allowlist is swapped into its artifact
            // store, so a mutation cannot change anything except the one field it is
            // about — and so the case pays for one release rather than twelve.
            //
            // They are also where the runtime goes: twelve seven-step startup gates per
            // case is a little over half of this property's wall clock, against a little
            // under half for the five synchronous arms above. Both are the cost of
            // quantifying exclusion where exclusion actually happens.
            guard let release = await scenario.bindRelease() else { return }
            await scenario.checkCoherentConfigurationIsAdmitted(release)
            await scenario.checkEveryVersionTupleMemberIsBinding(release)
            await scenario.checkEmptyPassingSetBlocksIngest(release)
        }

        witness.expectVariedBaselines()
    }
}

// MARK: - Generated shape

/// One candidate iPhone configuration, as plain data.
///
/// The hardware identifier's major component and the operating-system major version come
/// from the candidate's position in the list rather than from a draw, so two candidates
/// of one allowlist can never collide on the uniqueness key
/// ``ReleaseApprovedDeviceAllowlist`` enforces. Colliding is its own refusal, asserted in
/// the eligibility arm; a baseline that collided by chance would fail for that reason
/// instead of the one an arm is about.
private struct CandidateShape: Sendable {
    let hardwareMinor: Int
    let osMinor: Int
    let osPatch: Int
}

/// Which member of each enumerable set a mutation arm breaks.
///
/// Generated rather than enumerated so the shrinker can reduce a failing arm to one gate,
/// and so 100 cases spread across the sets instead of every case paying for all of them.
private struct Selectors: Sendable {
    let gate: Int
    let candidate: Int
    let capability: Int
}

/// Everything the device-allowlisting layer reads, as plain data.
///
/// The generator produces data only. Artifacts are built from it inside the property
/// body, where a construction that unexpectedly throws is recorded as a failure rather
/// than escaping: `propertyCheck` discards an error thrown by its body, so a refusal that
/// escaped as a throw would pass vacuously.
///
/// ## How the baseline varies
///
/// A property whose baseline is one constant with a mutation applied asserts one example
/// a hundred times over, so every dimension the arms depend on is generated:
///
///   * one to three candidate configurations, each with its own hardware identifier and
///     its own exact operating-system version at or above the iOS 17.0 floor;
///   * every capability set a release can enable, over the two conditional capabilities.
///     The set changes which mandatory gate is conditional, which implementation versions
///     the tuple has to carry, and which policy artifacts the release binds at all.
///     Fusion is *derived* from provenance rather than drawn independently, because
///     Requirement 7.16 needs both lanes for a Combined Summary and a fusion-without-
///     provenance manifest is not a representable release: generating one would make
///     every case fail for a reason this property is not about;
///   * the mandatory gate each mutation arm breaks, over every gate the generated
///     capability set makes applicable;
///   * the application build, Model Bundle, and every configuration identifier, from
///     ``seed``. Deriving the reference set from one number keeps it coherent without a
///     cross-reference table while still varying each reference between cases.
///
/// Three identifiers are deliberately *not* generated, because the existing coherent
/// release fixtures pin them and this task may not edit those fixtures: the capability
/// manifest (``StartupPreflight`` is constructed with a fixed manifest identifier), the
/// Device Validation Plan (the sample Resource Budgets name it), and the Release Fixture
/// Suite (the sample Evidence Fusion Rule names it). Each mutation arm still generates
/// the value it moves the entry *to*, so no arm compares two constants.
///
/// ``DeviceAllowlistVariationWitness`` checks after the run that this actually happened.
private struct AllowlistShape: Sendable, CustomStringConvertible {
    /// Drives every synthetic identifier, so the whole reference set varies together and
    /// stays coherent without a cross-reference table.
    let seed: Int

    let provenanceEnabled: Bool

    /// Whether this release would enable fusion if it could.
    ///
    /// Not the answer on its own: see ``fusionEnabled``.
    let fusionDraw: Bool

    let candidates: [CandidateShape]
    let selectors: Selectors

    /// Whether this release enables Combined Summary production.
    ///
    /// Derived rather than drawn. Requirement 7.16 needs both evidence lanes for a
    /// Combined Summary, so ``ReleaseCapabilityManifest`` refuses a compiled fusion
    /// capability with the provenance lane unavailable. Drawing the two independently
    /// would spend a quarter of the generated cases on a release that cannot exist.
    var fusionEnabled: Bool { provenanceEnabled && fusionDraw }

    /// The mandatory gates, in a fixed order so a generated selector indexes into them
    /// deterministically.
    static let mandatoryGates: [DeviceGate] = DeviceGate.mandatoryGates
        .sorted { $0.rawValue < $1.rawValue }

    /// The mandatory gates that apply to this release's capability set.
    ///
    /// Derived rather than drawn. A conditional gate's applicability follows the enabled
    /// capabilities, so an arm that recorded an outcome for a gate this release declared
    /// inapplicable would be refused for that disagreement — which the eligibility arm
    /// asserts on purpose, in both directions — instead of for the outcome it is about.
    var applicableGates: [DeviceGate] {
        Self.mandatoryGates.filter { !$0.isProvenanceConditional || provenanceEnabled }
    }

    /// The applicable gate this case's mutation arms break.
    var selectedGate: DeviceGate {
        let gates = applicableGates
        return gates[selectors.gate % gates.count]
    }

    /// Environments whose results can never satisfy a device gate (Requirement 13.16).
    ///
    /// Derived from the whole vocabulary rather than listed, so an environment added to
    /// ``ExecutionEnvironment`` is covered by the physical-device arm automatically.
    static let nonPhysicalEnvironments: [ExecutionEnvironment] = ExecutionEnvironment.allCases
        .filter { !$0.isPhysicalDeviceEvidence }
        .sorted { $0.rawValue < $1.rawValue }

    /// Every top-level member ``ValidationVersionTuple`` encodes.
    ///
    /// Asserted against ``CanonicalArtifactPayload/topLevelKeys(_:)`` rather than trusted
    /// as a written list, so a member added to the tuple fails that assertion instead of
    /// being silently skipped by the version-tuple arm.
    static let versionTupleMembers = [
        "appBuild",
        "capabilities",
        "capabilityImplementationVersions",
        "capabilityManifest",
        "fixtureSuite",
        "modelBundle",
        "validationPlan",
    ]

    var description: String {
        """
        seed \(seed), \(candidates.count) candidate(s), provenance \(provenanceEnabled), \
        fusion \(fusionEnabled), gate \(selectedGate.rawValue)
        """
    }

    // MARK: Generators

    static var generator: Generator<AllowlistShape, AnySequence<Any>> {
        zip(Gen.int(in: 0...9_999), Gen.bool, Gen.bool, candidates, selectors)
            .map { raw in
                AllowlistShape(
                    seed: raw.0,
                    provenanceEnabled: raw.1,
                    fusionDraw: raw.2,
                    candidates: raw.3,
                    selectors: raw.4
                )
            }
            .eraseToAny()
    }

    private static var candidates: Generator<[CandidateShape], AnySequence<Any>> {
        zip(Gen.int(in: 0...9), Gen.int(in: 0...9), Gen.int(in: 0...9))
            .map { CandidateShape(hardwareMinor: $0.0, osMinor: $0.1, osPatch: $0.2) }
            .array(of: 1...3)
            .eraseToAny()
    }

    private static var selectors: Generator<Selectors, AnySequence<Any>> {
        zip(Gen.int(in: 0...99), Gen.int(in: 0...99), Gen.int(in: 0...99))
            .map { Selectors(gate: $0.0, candidate: $0.1, capability: $0.2) }
            .eraseToAny()
    }
}

// MARK: - Gate evidence table

/// One gate's recorded evidence, as plain data.
///
/// Every arm that changes gate evidence edits this table and lets the references be
/// rebuilt from it, so a mutation cannot leave the applicability, the outcome, and the
/// environment of one gate disagreeing about anything except the one thing the arm is
/// about.
private struct GateEvidenceShape: Sendable {
    var applicable: Bool
    var inapplicabilityApproved: Bool
    var outcome: GateOutcome
    var environment: ExecutionEnvironment
}

// MARK: - A bound release

/// A built coherent release and the allowlist registered in it.
///
/// The allowlist is carried alongside so every arm can restore it after swapping in a
/// mutated one: the artifact store is shared for the whole case, and an arm that left a
/// mutation behind would silently change what the next arm is testing.
private struct BoundRelease {
    let scenario: PreflightScenario
    let coherentAllowlist: ReleaseApprovedDeviceAllowlist
}

// MARK: - Scenario

/// A generated shape and the artifacts built from it.
private struct AllowlistScenario {
    let shape: AllowlistShape

    // MARK: Identifiers and scalars

    private var seed: Int { shape.seed }

    private func artifact(_ raw: String) -> ArtifactID { ArtifactID(raw)! }

    /// The application build this release is, generated so no arm compares two constants.
    var appBuildID: AppBuildID { AppBuildID("build.app-\(seed)")! }

    /// An application build this release is not.
    var otherAppBuildID: AppBuildID { AppBuildID("build.app-other-\(seed)")! }

    var bundleID: ModelBundleID { ModelBundleID("bundle.model-\(seed)")! }
    var otherBundleID: ModelBundleID { ModelBundleID("bundle.model-other-\(seed)")! }

    /// Pinned by ``StartupPreflight``'s fixed manifest identifier in the existing release
    /// fixture. The value an arm moves an entry *to* is still generated.
    var manifestID: ArtifactID { artifact("manifest.capability") }
    var otherManifestID: ArtifactID { artifact("manifest.other-\(seed)") }

    /// Pinned by the sample Resource Budgets, which name this plan.
    var planID: ArtifactID { artifact("plan.device-validation") }
    var otherPlanID: ArtifactID { artifact("plan.other-\(seed)") }

    /// Pinned by the sample Evidence Fusion Rule, which names this suite.
    var suiteID: ArtifactID { artifact("suite.fixtures") }
    var otherSuiteID: ArtifactID { artifact("suite.other-\(seed)") }

    func configurationID(_ offset: Int) -> ApprovedConfigurationID {
        ApprovedConfigurationID("configuration.candidate-\(seed)-\(offset)")!
    }

    /// The capability set this release enables, and therefore the set every gate record
    /// has to have been produced under.
    var capabilities: Set<CapabilityID> {
        PreflightSample.capabilities(
            provenance: shape.provenanceEnabled,
            fusion: shape.fusionEnabled
        )
    }

    /// One implementation version per enabled capability, pinning the validator to the
    /// version the sample Provenance Policy declares.
    var implementationVersions: [CapabilityImplementationEntry] {
        PreflightSample.implementationVersions(for: capabilities)
    }

    var compositionIdentifier: String {
        shape.provenanceEnabled ? "pixel-plus-provenance" : "pixel-only"
    }

    /// The applicable mandatory gate this case's mutation arms break.
    var selectedGate: DeviceGate { shape.selectedGate }

    /// The same selection restricted to a gate whose applicability this release does not
    /// fix, for the one sub-arm that moves a gate to `notApplicable`.
    ///
    /// The conditional gate's applicability follows the capability set in both directions,
    /// so declaring *it* inapplicable is either already the baseline or a disagreement the
    /// eligibility arm asserts. Neither is a test of what an inapplicability decision
    /// means.
    var selectedUnconditionalGate: DeviceGate {
        let gates = AllowlistShape.mandatoryGates.filter { !$0.isProvenanceConditional }
        return gates[shape.selectors.gate % gates.count]
    }

    /// The gate the entry at `offset` fails, in the arm where every entry fails one.
    ///
    /// Rotated by position so the arm does not test one gate `count` times.
    func failingGate(_ offset: Int) -> DeviceGate {
        let gates = shape.applicableGates
        return gates[(shape.selectors.gate + offset) % gates.count]
    }

    /// The candidate this case's single-entry arms target.
    var selectedOffset: Int { shape.selectors.candidate % shape.candidates.count }

    /// The enabled capability whose implementation version an arm rewrites.
    var selectedCapability: CapabilityID {
        let sorted = capabilities.sorted { $0.rawValue < $1.rawValue }
        return sorted[shape.selectors.capability % sorted.count]
    }

    /// The device this process is running as: the first generated candidate.
    var runningDevice: DeviceContext {
        DeviceContext(
            hardwareIdentifier: hardware(0),
            osVersion: osVersion(0),
            appBuild: appBuildID,
            environment: .physicalIPhone
        )
    }

    // MARK: Candidate configurations

    /// The exact hardware identifier of the candidate at `offset`.
    ///
    /// The major component is the position, so two candidates never collide.
    func hardware(_ offset: Int) -> DeviceHardwareID {
        let candidate = shape.candidates[offset % shape.candidates.count]
        return DeviceHardwareID("iPhone\(17 + offset).\(candidate.hardwareMinor)")!
    }

    /// A hardware identifier no generated candidate carries.
    var unlistedHardware: DeviceHardwareID {
        DeviceHardwareID("iPhone\(20 + shape.candidates.count).\(seed % 10)")!
    }

    /// The exact operating-system version of the candidate at `offset`, at or above the
    /// iOS 17.0 floor by construction.
    func osVersion(_ offset: Int) -> PlatformVersion {
        let candidate = shape.candidates[offset % shape.candidates.count]
        return try! PlatformVersion(
            validating: "\(17 + offset).\(candidate.osMinor).\(candidate.osPatch)"
        )
    }

    /// The same version one patch release later: a version this release lists for nobody.
    func unlistedOSVersion(_ offset: Int) -> PlatformVersion {
        let candidate = shape.candidates[offset % shape.candidates.count]
        return try! PlatformVersion(
            validating: "\(17 + offset).\(candidate.osMinor).\(candidate.osPatch + 10)"
        )
    }

    /// The same version below the iOS 17.0 floor (Requirement 13.2).
    func belowFloorOSVersion(_ offset: Int) -> PlatformVersion {
        let candidate = shape.candidates[offset % shape.candidates.count]
        return try! PlatformVersion(validating: "16.\(candidate.osMinor).\(candidate.osPatch)")
    }

    func candidate(
        _ offset: Int,
        osVersion overriddenOS: PlatformVersion? = nil,
        appBuild: AppBuildID? = nil,
        appleNeuralEngineCapable: Bool = true
    ) throws -> CandidateDeviceConfiguration {
        try CandidateDeviceConfiguration(
            deviceModel: Sample.text("Synthetic iPhone \(seed)-\(offset)"),
            hardwareIdentifier: hardware(offset),
            osVersion: overriddenOS ?? osVersion(offset),
            appBuild: appBuild ?? appBuildID,
            isAppleNeuralEngineCapable: appleNeuralEngineCapable
        )
    }

    // MARK: Version tuple

    /// The coherent tuple, or the same tuple with one member replaced.
    ///
    /// Implementation versions are derived from the capability set unless an arm replaces
    /// them, so the exact-coverage rule the tuple enforces holds for whatever capability
    /// set an arm hands in and no generated case fails for that reason.
    func versionTuple(
        appBuild: AppBuildID? = nil,
        modelBundle: ModelBundleID? = nil,
        fixtureSuite: ArtifactID? = nil,
        validationPlan: ArtifactID? = nil,
        capabilityManifest: ArtifactID? = nil,
        capabilities overriddenCapabilities: Set<CapabilityID>? = nil,
        implementationVersions overriddenVersions: [CapabilityImplementationEntry]? = nil
    ) throws -> ValidationVersionTuple {
        let set = overriddenCapabilities ?? capabilities
        return try ValidationVersionTuple(
            appBuild: appBuild ?? appBuildID,
            modelBundle: modelBundle ?? bundleID,
            fixtureSuite: fixtureSuite ?? suiteID,
            validationPlan: validationPlan ?? planID,
            capabilityManifest: capabilityManifest ?? manifestID,
            capabilities: set,
            capabilityImplementationVersions: overriddenVersions
                ?? PreflightSample.implementationVersions(for: set)
        )
    }

    /// The implementation versions with one capability's version rewritten.
    var restampedImplementationVersions: [CapabilityImplementationEntry] {
        implementationVersions.map { entry in
            entry.capability == selectedCapability
                ? CapabilityImplementationEntry(
                    capability: entry.capability,
                    version: Sample.version("9.\(seed % 1_000).0")
                )
                : entry
        }
    }

    // MARK: Gate evidence

    /// The coherent evidence table: every mandatory gate passing on a physical iPhone,
    /// with the provenance-conditional gate applicable exactly when the capability set
    /// enables provenance.
    func coherentGateEvidence() -> [DeviceGate: GateEvidenceShape] {
        var table: [DeviceGate: GateEvidenceShape] = [:]
        for gate in AllowlistShape.mandatoryGates {
            let applicable = !gate.isProvenanceConditional || shape.provenanceEnabled
            table[gate] = GateEvidenceShape(
                applicable: applicable,
                inapplicabilityApproved: true,
                outcome: applicable ? .passed : .notExecuted,
                environment: .physicalIPhone
            )
        }
        return table
    }

    /// References built from an evidence table, minus whatever an arm dropped, plus
    /// whatever an arm repeated.
    func gateReferences(
        from table: [DeviceGate: GateEvidenceShape],
        omitting omitted: DeviceGate? = nil,
        repeating repeated: DeviceGate? = nil
    ) throws -> [GateResultReference] {
        var gates = AllowlistShape.mandatoryGates.filter { $0 != omitted }
        if let repeated { gates.append(repeated) }
        return try gates.map { gate in
            guard let evidence = table[gate] else {
                throw ArtifactSchemaError.missingRequiredEntries(
                    field: "test.gateEvidence",
                    keys: [gate.rawValue]
                )
            }
            return try GateResultReference(
                gate: gate,
                applicability: evidence.applicable
                    ? .applicable
                    : Sample.notApplicable(
                        evidence.inapplicabilityApproved ? .approved : .rejected
                    ),
                outcome: evidence.outcome,
                result: Sample.evidence("evidence.device.\(gate.rawValue)-\(seed)"),
                environment: evidence.environment
            )
        }
    }

    /// The evidence table with one applicable gate's recorded outcome and environment
    /// replaced.
    ///
    /// `gate` comes from ``AllowlistShape/applicableGates``, so the applicability it keeps
    /// agrees with this release's capability set: a conditional gate this release declared
    /// inapplicable would be refused for that disagreement rather than for its outcome.
    func gateEvidence(
        _ gate: DeviceGate,
        outcome: GateOutcome,
        environment: ExecutionEnvironment = .physicalIPhone
    ) -> [DeviceGate: GateEvidenceShape] {
        var table = coherentGateEvidence()
        table[gate] = GateEvidenceShape(
            applicable: true,
            inapplicabilityApproved: true,
            outcome: outcome,
            environment: environment
        )
        return table
    }

    // MARK: Entries and the allowlist

    /// One allowlist entry, coherent unless an argument replaces exactly one thing.
    func entry(
        _ offset: Int,
        configuration overriddenCandidate: CandidateDeviceConfiguration? = nil,
        versionTuple overriddenTuple: ValidationVersionTuple? = nil,
        gateEvidence table: [DeviceGate: GateEvidenceShape]? = nil,
        omittingGate omitted: DeviceGate? = nil,
        repeatingGate repeated: DeviceGate? = nil
    ) throws -> ApprovedDeviceConfiguration {
        try ApprovedDeviceConfiguration(
            id: configurationID(offset),
            configuration: try overriddenCandidate ?? candidate(offset),
            versionTuple: try overriddenTuple ?? versionTuple(),
            gateEvidence: try gateReferences(
                from: table ?? coherentGateEvidence(),
                omitting: omitted,
                repeating: repeated
            )
        )
    }

    /// The coherent entry set: one per generated candidate.
    func coherentEntries() throws -> [ApprovedDeviceConfiguration] {
        try shape.candidates.indices.map { try entry($0) }
    }

    /// The coherent entry set with the matched entry replaced.
    ///
    /// Every sibling stays exactly what the coherent baseline built, so a refusal is
    /// attributable to the replacement and not to a second disagreement.
    func entries(replacingMatched replacement: ApprovedDeviceConfiguration) throws
        -> [ApprovedDeviceConfiguration]
    {
        try shape.candidates.indices.map { $0 == 0 ? replacement : try entry($0) }
    }

    /// A sibling entry beyond the generated candidates, coherent unless `versionTuple`
    /// replaces one thing.
    ///
    /// Two arms need one. The version-mixing checks compare *siblings* under one manifest,
    /// so a shape that generated a single candidate has nothing to mix with: a shipping
    /// build binds no fixture suite of its own, and the only runtime evidence that an entry
    /// names the wrong suite is a second entry naming a different one. The
    /// Requirement 13.19 arm needs a distributable entry that is not the matched one.
    ///
    /// Its hardware major and operating-system major are past every generated candidate's,
    /// so it can never collide on the allowlist's uniqueness key.
    func extraSibling(
        versionTuple overriddenTuple: ValidationVersionTuple? = nil
    ) throws -> ApprovedDeviceConfiguration {
        let offset = shape.candidates.count
        return try ApprovedDeviceConfiguration(
            id: configurationID(offset),
            configuration: try CandidateDeviceConfiguration(
                deviceModel: Sample.text("Synthetic iPhone \(seed)-\(offset)"),
                hardwareIdentifier: DeviceHardwareID("iPhone\(17 + offset).\(seed % 10)")!,
                osVersion: try PlatformVersion(validating: "\(17 + offset).0.0"),
                appBuild: appBuildID,
                isAppleNeuralEngineCapable: true
            ),
            versionTuple: try overriddenTuple ?? versionTuple(),
            gateEvidence: try gateReferences(from: coherentGateEvidence())
        )
    }

    func allowlist(entries: [ApprovedDeviceConfiguration]) throws
        -> ReleaseApprovedDeviceAllowlist
    {
        try ReleaseApprovedDeviceAllowlist(
            id: artifact("allowlist.devices"),
            schemaVersion: .v1,
            entries: entries,
            approval: Sample.approval(identifier: "approval.allowlist-\(seed)")
        )
    }

    func coherentAllowlist() throws -> ReleaseApprovedDeviceAllowlist {
        try allowlist(entries: try coherentEntries())
    }

    // MARK: - Eligibility arm

    /// Only an Apple Neural Engine-capable iPhone at or above iOS 17.0, described by one
    /// coherent tuple, is representable at all.
    ///
    /// Requirements 13.2 and 1.4 are about what an entry may contain, and the schema
    /// enforces them by making the alternative unbuildable. Asserting at that layer
    /// rather than at the allowlist is deliberate: there is no entry to exclude.
    ///
    /// The floor is asserted inclusive as well as exclusive. "iOS 17 or later" with a
    /// refusal at exactly 17.0.0 would be a different requirement, and a validator that
    /// refused every version would satisfy the exclusions below.
    func checkOnlyEligibleConfigurationsAreRepresentable() {
        for offset in shape.candidates.indices {
            do {
                let accepted = try candidate(offset)
                #expect(accepted.osVersion == osVersion(offset))
                #expect(accepted.hardwareIdentifier == hardware(offset))
                #expect(accepted.isAppleNeuralEngineCapable)
            } catch {
                Issue.record("an eligible generated candidate was refused: \(error) [\(shape)]")
            }

            expectSchemaRefusal(
                "a candidate on iOS \(belowFloorOSVersion(offset))", .valueOutOfRange
            ) {
                _ = try self.candidate(offset, osVersion: self.belowFloorOSVersion(offset))
            }
        }

        // The floor itself. Every generated version is at or above it and almost none is
        // exactly it, so the inclusive boundary needs asserting on its own.
        do {
            _ = try candidate(0, osVersion: .iOS17)
        } catch {
            Issue.record("the iOS 17.0 floor was refused: \(error) [\(shape)]")
        }

        expectSchemaRefusal("a candidate without Apple Neural Engine", .forbiddenValue) {
            _ = try self.candidate(0, appleNeuralEngineCapable: false)
        }

        // Requirement 13.20 inside one entry: the build the candidate ran and the build
        // its evidence was recorded under are separate fields, so they can disagree.
        expectSchemaRefusal(
            "an entry whose two application builds disagree", .inconsistentReference
        ) {
            _ = try self.entry(
                0,
                configuration: try self.candidate(0, appBuild: self.otherAppBuildID)
            )
        }

        // Requirement 13.17: a capability with no recorded implementation version, and a
        // recorded version for a capability this release does not enable, are both
        // incoherent tuples rather than partial ones.
        expectSchemaRefusal(
            "a tuple missing an implementation version", .missingRequiredEntries
        ) {
            _ = try self.versionTuple(
                implementationVersions: self.implementationVersions.filter {
                    $0.capability != self.selectedCapability
                }
            )
        }
        expectSchemaRefusal(
            "a tuple with an unenabled implementation version", .unexpectedEntries
        ) {
            _ = try self.versionTuple(
                implementationVersions: self.implementationVersions + [
                    CapabilityImplementationEntry(
                        capability: .shareExtensionHandoff,
                        version: Sample.version()
                    )
                ]
            )
        }
        expectSchemaRefusal("a tuple with no pixel analysis", .missingRequiredEntries) {
            _ = try self.versionTuple(capabilities: [.contentCredentialValidation])
        }

        // Requirement 13.5: the conditional gate carries a decision that follows the
        // capability set, in both directions, so a capability cannot become enabled or
        // waived by an applicability field.
        let conditional = AllowlistShape.mandatoryGates.filter(\.isProvenanceConditional)
        for gate in conditional {
            var table = coherentGateEvidence()
            table[gate] = GateEvidenceShape(
                applicable: !shape.provenanceEnabled,
                inapplicabilityApproved: true,
                outcome: shape.provenanceEnabled ? .notExecuted : .passed,
                environment: .physicalIPhone
            )
            let declared = shape.provenanceEnabled
                ? "not applicable with the provenance capability"
                : "applicable without the provenance capability"
            expectSchemaRefusal("\(gate.rawValue) declared \(declared)", .inconsistentReference) {
                _ = try self.entry(0, gateEvidence: table)
            }
        }

        // The uniqueness keys the allowlist enforces, so no arm's baseline can collide
        // and be refused for that instead.
        expectSchemaRefusal("two entries with one identifier", .duplicateEntry) {
            _ = try self.allowlist(entries: [try self.entry(0), try self.entry(0)])
        }
        expectSchemaRefusal("two entries for one configuration", .duplicateEntry) {
            let duplicate = try ApprovedDeviceConfiguration(
                id: self.configurationID(shape.candidates.count),
                configuration: try self.candidate(0),
                versionTuple: try self.versionTuple(),
                gateEvidence: try self.gateReferences(from: self.coherentGateEvidence())
            )
            _ = try self.allowlist(entries: [try self.entry(0), duplicate])
        }
    }

    // MARK: - Physical-device evidence arm

    /// Only a physical-iPhone result satisfies a device gate (Requirement 13.16).
    ///
    /// Two forms, and they are different findings. A *passing* applicable gate claimed
    /// from a simulator or a development Mac is unrepresentable: that is the point where
    /// a recording would become release evidence, so the schema refuses it. The same
    /// environment recorded *honestly* — the run happened, it produced no pass — is
    /// representable, because a runner has to be able to write down what it observed, and
    /// it leaves the gate unsatisfied.
    ///
    /// The physical-iPhone pass is the positive control. Without it "unsatisfied" could
    /// be unconditional and every refusal below would hold vacuously.
    func checkOnlyPhysicalIPhoneEvidenceSatisfiesAGate() {
        let gate = selectedGate
        do {
            let satisfied = try entry(0, gateEvidence: gateEvidence(gate, outcome: .passed))
            #expect(satisfied.unsatisfiedGates.isEmpty, "a physical-iPhone pass [\(shape)]")
        } catch {
            Issue.record("a physical-iPhone pass was refused: \(error) [\(shape)]")
        }

        #expect(
            !AllowlistShape.nonPhysicalEnvironments.isEmpty,
            "the environment vocabulary no longer contains a non-physical member"
        )

        for environment in AllowlistShape.nonPhysicalEnvironments {
            expectSchemaRefusal(
                "a \(gate.rawValue) pass claimed from \(environment.rawValue)", .forbiddenValue
            ) {
                _ = try self.entry(
                    0,
                    gateEvidence: self.gateEvidence(
                        gate,
                        outcome: .passed,
                        environment: environment
                    )
                )
            }

            // Recorded honestly rather than claimed as a pass. Requirement 13.16 is not
            // satisfied by it, and the recording is not refused either: a result nobody
            // can write down is a result nobody can audit.
            do {
                let listed = try entry(
                    0,
                    gateEvidence: gateEvidence(
                        gate,
                        outcome: .notExecuted,
                        environment: environment
                    )
                )
                #expect(
                    listed.unsatisfiedGates == [gate],
                    "\(environment.rawValue) evidence left \(listed.unsatisfiedGates) [\(shape)]"
                )
                let permitted = try allowlist(entries: [listed]).permitsDistribution
                #expect(
                    !permitted,
                    """
                    \(environment.rawValue) evidence for \(gate.rawValue) permitted \
                    distribution [\(shape)]
                    """
                )
            } catch {
                Issue.record(
                    "\(environment.rawValue) evidence could not be recorded: \(error) [\(shape)]"
                )
            }
        }
    }

    // MARK: - Missing or failing evidence arm

    /// Missing or failing mandatory evidence excludes the configuration, and it stays
    /// listed while it does (Requirements 13.19 and 13.21).
    ///
    /// "Missing" has three representable forms and they are different audit findings: the
    /// gate ran and failed; the gate has a record that says it never ran; and the gate has
    /// no record at all, which is not an entry. Only the third is a schema refusal, and
    /// that asymmetry is the whole reason `unsatisfiedGates` exists — an entry with a
    /// failed gate has to be expressible so a release can point at it.
    ///
    /// The entry remaining a member is asserted deliberately. Requirement 13.19 excludes
    /// the configuration from *approval*, and ``ValidatedAccessibilityGateMatrix`` relies
    /// on it not vanishing from the artifact: it derives required accessibility coverage
    /// from every entry whatever that entry's own gates say, so an entry that disappeared
    /// on failing a gate would leave the remaining coverage looking complete.
    func checkMissingOrFailingEvidenceExcludes() {
        let gate = selectedGate

        for outcome in [GateOutcome.failed, .notExecuted] {
            do {
                let excluded = try entry(0, gateEvidence: gateEvidence(gate, outcome: outcome))
                #expect(
                    excluded.unsatisfiedGates == [gate],
                    "\(outcome.rawValue) left \(excluded.unsatisfiedGates) [\(shape)]"
                )

                let listed = try allowlist(entries: try entries(replacingMatched: excluded))
                // Still a member, and still found by its exact triple.
                #expect(listed.entries.count == shape.candidates.count)
                let found = listed.entry(
                    hardwareIdentifier: hardware(0),
                    osVersion: osVersion(0),
                    appBuild: appBuildID
                )
                #expect(
                    found?.id == excluded.id,
                    "a \(outcome.rawValue) gate removed the entry from the allowlist [\(shape)]"
                )
                #expect(found == excluded, "a \(outcome.rawValue) gate altered the entry")
            } catch {
                Issue.record(
                    """
                    a \(outcome.rawValue) \(gate.rawValue) could not be recorded: \
                    \(error) [\(shape)]
                    """
                )
            }
        }

        // Presence is not approval: an inapplicability decision that is a rejection
        // declares nothing, so the gate is still unsatisfied.
        let unconditional = selectedUnconditionalGate
        do {
            var table = coherentGateEvidence()
            table[unconditional] = GateEvidenceShape(
                applicable: false,
                inapplicabilityApproved: false,
                outcome: .notExecuted,
                environment: .physicalIPhone
            )
            let rejected = try entry(0, gateEvidence: table)
            #expect(
                rejected.unsatisfiedGates == [unconditional],
                """
                a rejected inapplicability decision left \(rejected.unsatisfiedGates) for \
                \(unconditional.rawValue) [\(shape)]
                """
            )
            let permitted = try allowlist(entries: [rejected]).permitsDistribution
            #expect(!permitted, "a rejected inapplicability permitted distribution [\(shape)]")
        } catch {
            Issue.record("a rejected inapplicability could not be recorded: \(error) [\(shape)]")
        }

        expectSchemaRefusal("an entry with no \(gate.rawValue) record", .missingRequiredEntries) {
            _ = try self.entry(0, omittingGate: gate)
        }
        expectSchemaRefusal("an entry recording \(gate.rawValue) twice", .duplicateEntry) {
            _ = try self.entry(0, repeatingGate: gate)
        }
    }

    // MARK: - Exact matching arm

    /// Membership is looked up on the exact hardware identifier, operating-system
    /// version, and application build, and on nothing else (Requirement 13.18).
    ///
    /// Every sibling is checked against its own triple as well, so the lookup is shown to
    /// select rather than to return whatever is first. The near misses are one component
    /// away from a listed entry, which is what makes them a test of exactness: a lookup
    /// that matched on device family, on a minimum version, or on two of the three
    /// components would admit each of them.
    func checkMatchingIsExactAndVersionBound() {
        let listed: ReleaseApprovedDeviceAllowlist
        do {
            listed = try coherentAllowlist()
        } catch {
            Issue.record("a coherent generated allowlist was refused: \(error) [\(shape)]")
            return
        }

        let permitted = listed.permitsDistribution
        #expect(permitted, "a fully satisfied allowlist permitted no distribution [\(shape)]")

        for offset in shape.candidates.indices {
            #expect(
                listed.entry(
                    hardwareIdentifier: hardware(offset),
                    osVersion: osVersion(offset),
                    appBuild: appBuildID
                )?.id == configurationID(offset),
                "candidate \(offset) was not found by its own triple [\(shape)]"
            )
        }

        let offset = selectedOffset
        for (what, hardwareIdentifier, version, build) in [
            (
                "an unlisted hardware identifier",
                unlistedHardware, osVersion(offset), appBuildID
            ),
            (
                "a listed device on an unlisted operating-system version",
                hardware(offset), unlistedOSVersion(offset), appBuildID
            ),
            (
                "a listed device running an unlisted application build",
                hardware(offset), osVersion(offset), otherAppBuildID
            ),
        ] as [(String, DeviceHardwareID, PlatformVersion, AppBuildID)] {
            #expect(
                listed.entry(
                    hardwareIdentifier: hardwareIdentifier,
                    osVersion: version,
                    appBuild: build
                ) == nil,
                "\(what) matched an entry [\(shape)]"
            )
        }
    }

    // MARK: - Empty passing set arm

    /// An allowlist that approves nothing is a valid artifact that permits no
    /// distribution (Requirement 13.22).
    ///
    /// The requirement says to block distribution, not that the artifact is invalid, and
    /// the two readings are not interchangeable. An empty allowlist has to be
    /// constructible — a release that has validated nothing yet has an empty one — so
    /// emptiness is reported by ``ReleaseApprovedDeviceAllowlist/permitsDistribution``
    /// rather than raised as a schema fault. Asserting a refusal here would pin the wrong
    /// behavior and would make an honest empty allowlist unrepresentable.
    ///
    /// "Empty passing set" is also not "empty allowlist": the set that has to be nonempty
    /// is the set of entries with every mandatory gate satisfied. An allowlist of three
    /// entries that each fail one gate approves exactly as much as an empty one, and each
    /// of those three is still a member. The control at the end is what keeps this arm
    /// from holding for a `permitsDistribution` that is simply always false.
    func checkEmptyPassingSetPermitsNoDistribution() {
        do {
            let empty = try allowlist(entries: [])
            #expect(empty.entries.isEmpty)
            // Bound to a local rather than asserted on the value, so a failure names the
            // decision instead of printing a whole allowlist.
            let permitted = empty.permitsDistribution
            #expect(!permitted, "an empty allowlist permitted distribution [\(shape)]")
            #expect(
                empty.entry(
                    hardwareIdentifier: hardware(0),
                    osVersion: osVersion(0),
                    appBuild: appBuildID
                ) == nil
            )
        } catch {
            Issue.record("an empty allowlist was refused: \(error) [\(shape)]")
        }

        do {
            let failing = try shape.candidates.indices.map { offset in
                try entry(
                    offset,
                    gateEvidence: gateEvidence(failingGate(offset), outcome: .failed)
                )
            }
            let exhausted = try allowlist(entries: failing)

            // The entry set is exactly the coherent one's. This is the invariant
            // ``ValidatedAccessibilityGateMatrix`` depends on: it derives required
            // accessibility coverage from every entry of the signed allowlist, so a
            // consumer reading `entries` after a gate failed still sees the same
            // configurations to have tested.
            #expect(exhausted.entries.count == shape.candidates.count)
            #expect(
                exhausted.entries.map(\.id) == shape.candidates.indices.map(configurationID),
                "failing a gate changed which configurations the allowlist lists [\(shape)]"
            )
            let permitted = exhausted.permitsDistribution
            #expect(
                !permitted,
                "an allowlist whose every entry fails a gate permitted distribution [\(shape)]"
            )
            for (offset, entry) in failing.enumerated() {
                #expect(
                    entry.unsatisfiedGates == [failingGate(offset)],
                    "entry \(offset) reported \(entry.unsatisfiedGates) [\(shape)]"
                )
                let found = exhausted.entry(
                    hardwareIdentifier: hardware(offset),
                    osVersion: osVersion(offset),
                    appBuild: appBuildID
                )
                #expect(
                    found?.id == entry.id,
                    "a failing entry stopped being a member [\(shape)]"
                )
                #expect(found == entry, "a failing entry was altered [\(shape)]")
            }

            // The control. One clean entry is the whole difference between blocked and
            // permitted, and the entry that is cleaned is the *last* candidate rather than
            // the matched one, so the permission comes from the set rather than from this
            // device.
            var restored = failing
            restored[restored.count - 1] = try entry(shape.candidates.count - 1)
            let restoredPermits = try allowlist(entries: restored).permitsDistribution
            #expect(
                restoredPermits,
                "one satisfied entry did not restore distribution [\(shape)]"
            )
        } catch {
            Issue.record("an exhausted allowlist could not be built: \(error) [\(shape)]")
        }
    }

    // MARK: - Admission arm

    /// Builds the coherent release this device is running in, or records why it could not.
    ///
    /// Returns rather than throws: `propertyCheck` discards an error thrown from its body,
    /// so a build failure that escaped would take the rest of the case with it silently.
    func bindRelease() async -> BoundRelease? {
        do {
            let allowlist = try coherentAllowlist()
            let scenario = try await PreflightSample.scenario(
                provenance: shape.provenanceEnabled,
                fusion: shape.fusionEnabled,
                device: runningDevice,
                manifest: try PreflightSample.capabilityManifest(
                    capabilities: capabilities,
                    compositionIdentifier: compositionIdentifier,
                    appBuild: appBuildID.rawValue,
                    approvedBundleCatalog: [bundleID.rawValue]
                ),
                allowlist: allowlist,
                bundle: try PreflightSample.boundBundle(
                    bundleID: bundleID.rawValue,
                    compatibleAppBuilds: [appBuildID.rawValue]
                ),
                embeddedBundle: bundleID.rawValue
            )
            return BoundRelease(scenario: scenario, coherentAllowlist: allowlist)
        } catch {
            Issue.record("a coherent generated release could not be built: \(error) [\(shape)]")
            return nil
        }
    }

    /// A coherent generated configuration is admitted, and everything the admission
    /// reports is what the shape generated (Requirement 13.18).
    ///
    /// Without this arm the property would pass by refusing everything. The equality
    /// against the entry the shape built is the second half of it: Requirement 13.18 adds
    /// *that exact version-bound configuration*, so a preflight that repaired, normalized,
    /// or substituted a field would satisfy every refusal arm below while admitting a
    /// configuration nobody approved.
    func checkCoherentConfigurationIsAdmitted(_ release: BoundRelease) async {
        let matched: ApprovedDeviceConfiguration
        let admission: ReleaseAdmission
        do {
            matched = try entry(0)
            admission = try await release.scenario.run()
        } catch {
            Issue.record("a coherent generated configuration was refused: \(error) [\(shape)]")
            return
        }

        #expect(admission.approvedConfiguration.id == matched.id)
        #expect(
            admission.approvedConfiguration == matched,
            "admission altered the entry [\(shape)]"
        )
        #expect(admission.approvedConfiguration.unsatisfiedGates.isEmpty)
        #expect(admission.approvedConfiguration.versionTuple.appBuild == appBuildID)
        #expect(admission.approvedConfiguration.versionTuple.modelBundle == bundleID)
        #expect(admission.approvedConfiguration.versionTuple.capabilities == capabilities)
        #expect(
            Set(admission.approvedConfiguration.versionTuple.capabilityImplementationVersions)
                == Set(implementationVersions)
        )
        #expect(admission.boundFixtureSuite == suiteID)
        #expect(admission.boundValidationPlan == planID)
        #expect(admission.context.device == runningDevice)
        #expect(admission.context.approvedConfiguration == configurationID(0))
        #expect(admission.context.capabilityManifestID == manifestID)
        #expect(admission.enablesProvenance == shape.provenanceEnabled)
        #expect(admission.enablesFusion == shape.fusionEnabled)

        // One reference per mandatory gate, so no two gates collapsed into one record.
        #expect(
            admission.approvedConfiguration.gateEvidence.count
                == AllowlistShape.mandatoryGates.count
        )
        #expect(
            Set(admission.approvedConfiguration.gateEvidence.map(\.gate))
                == DeviceGate.mandatoryGates
        )
        for reference in admission.approvedConfiguration.gateEvidence {
            #expect(reference.environment == .physicalIPhone, "\(reference.gate.rawValue)")
            #expect(reference.isSatisfied, "\(reference.gate.rawValue)")
        }
    }

    // MARK: - Version tuple arm

    /// Every member of the version tuple is binding: mutating one alone excludes the
    /// configuration (Requirements 13.18 and 13.20).
    ///
    /// The member list is read out of the encoded tuple rather than trusted as a written
    /// list, and the written list is asserted to equal it, so a member added to
    /// ``ValidationVersionTuple`` fails here instead of being silently skipped. Every
    /// member reached by the loop also has to be handled by name: the union means an
    /// unrecognised member reaches ``checkMemberIsBinding(_:in:)``'s default and records
    /// an issue rather than being dropped.
    func checkEveryVersionTupleMemberIsBinding(_ release: BoundRelease) async {
        let encoded: [String]
        do {
            encoded = try CanonicalArtifactPayload.topLevelKeys(try versionTuple())
        } catch {
            Issue.record("the generated version tuple could not be encoded: \(error) [\(shape)]")
            return
        }

        #expect(
            encoded == AllowlistShape.versionTupleMembers,
            "the version tuple gained or lost a member: \(encoded)"
        )

        for member in Set(encoded).union(AllowlistShape.versionTupleMembers).sorted() {
            await checkMemberIsBinding(member, in: release)
        }
    }

    private func checkMemberIsBinding(_ member: String, in release: BoundRelease) async {
        switch member {
        case "appBuild":
            // Evidence recorded under another application build. The candidate moves with
            // the tuple, because an entry whose two builds disagree is unrepresentable —
            // that refusal is the eligibility arm's. The running build is unchanged, so
            // no entry describes this binary and the exact lookup finds nothing.
            await expectRefused(
                "gate evidence recorded under another application build",
                .deviceNotAllowlisted,
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            configuration: try self.candidate(
                                0,
                                appBuild: self.otherAppBuildID
                            ),
                            versionTuple: try self.versionTuple(appBuild: self.otherAppBuildID)
                        )
                    )
                )
            }

        case "modelBundle":
            await expectRefused(
                "gate evidence recorded against a Model Bundle this release does not approve",
                .identityMismatch,
                reportedField: "allowlistEntry.versionTuple.modelBundle",
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            versionTuple: try self.versionTuple(modelBundle: self.otherBundleID)
                        )
                    )
                )
            }

        case "fixtureSuite":
            // A shipping build binds no fixture suite of its own, so what is checkable at
            // runtime is that two entries under one manifest do not name two suites. The
            // extra sibling supplies the second entry when the shape generated one
            // candidate; when it generated more, the mixing is between the mutated entry
            // and its coherent siblings either way.
            await expectRefused(
                "entries under one manifest naming two Release Fixture Suite versions",
                .mixedAllowlistVersions,
                reportedField: "deviceAllowlist.entries.versionTuple.fixtureSuite",
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            versionTuple: try self.versionTuple(fixtureSuite: self.otherSuiteID)
                        )
                    ) + [try self.extraSibling()]
                )
            }

        case "validationPlan":
            // Two directions, and they are different findings. The matched entry naming
            // another plan means this device's evidence was not produced under the plan
            // that supplied this build's limits; a *sibling* naming another plan means the
            // signed allowlist pools evidence from two plans under one manifest.
            await expectRefused(
                "gate evidence recorded under another Device Validation Plan",
                .identityMismatch,
                reportedField: "resourceBudgets.mainApplication.validationPlan",
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            versionTuple: try self.versionTuple(validationPlan: self.otherPlanID)
                        )
                    )
                )
            }
            await expectRefused(
                "entries under one manifest naming two Device Validation Plan versions",
                .mixedAllowlistVersions,
                reportedField: "deviceAllowlist.entries.versionTuple.validationPlan",
                in: release
            ) {
                // The matched entry is left coherent, so the plan the running build reads
                // agrees with this device's evidence and only the sibling disagrees.
                try self.allowlist(
                    entries: try self.coherentEntries() + [
                        try self.extraSibling(
                            versionTuple: try self.versionTuple(
                                validationPlan: self.otherPlanID
                            )
                        )
                    ]
                )
            }

        case "capabilityManifest":
            await expectRefused(
                "gate evidence bound to another capability manifest",
                .identityMismatch,
                reportedField: "allowlistEntry.versionTuple.capabilityManifest",
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            versionTuple: try self.versionTuple(
                                capabilityManifest: self.otherManifestID
                            )
                        )
                    )
                )
            }

        case "capabilities":
            // A capability set the module graph does not compile. The implementation
            // versions follow the set rather than being a second mutation, so the entry
            // is internally coherent and the only disagreement is with this build.
            await expectRefused(
                "gate evidence recorded under another capability set",
                .capabilitySetMismatch,
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            versionTuple: try self.versionTuple(
                                capabilities: self.capabilities.union([.shareExtensionHandoff])
                            )
                        )
                    )
                )
            }

        case "capabilityImplementationVersions":
            // The same capability set at another implementation version: the entry names
            // the right capabilities, so only the versions disagree.
            await expectRefused(
                "gate evidence recorded at another implementation version",
                .capabilitySetMismatch,
                in: release
            ) {
                try self.allowlist(
                    entries: try self.entries(
                        replacingMatched: try self.entry(
                            0,
                            versionTuple: try self.versionTuple(
                                implementationVersions: self.restampedImplementationVersions
                            )
                        )
                    )
                )
            }

        default:
            Issue.record(
                """
                the version tuple carries \(member), which no arm mutates, so a release \
                could mix it without being excluded [\(shape)]
                """
            )
        }
    }

    // MARK: - Empty passing set at the gate

    /// Nothing being distributable blocks ingest, and it is reported as the whole-set
    /// finding rather than as a fact about this device (Requirement 13.22).
    ///
    /// The three cases separate the three findings the requirement set distinguishes. An
    /// empty allowlist and an allowlist whose every entry fails both approve nothing, so
    /// both report ``PreflightFailure/allowlistApprovesNoConfiguration`` — including in
    /// the case where this device *does* match an entry exactly, which is what makes the
    /// ordering observable. When some other entry is distributable the finding becomes
    /// this configuration's unsatisfied gates, which is Requirement 13.19 rather than
    /// 13.22. A gate that reported the per-device finding in all three cases would tell an
    /// audit to go look at one iPhone when nothing at all had passed.
    func checkEmptyPassingSetBlocksIngest(_ release: BoundRelease) async {
        await expectRefused(
            "an allowlist with no entries", .allowlistApprovesNoConfiguration, in: release
        ) {
            try self.allowlist(entries: [])
        }

        await expectRefused(
            "an allowlist whose every entry fails a mandatory gate",
            .allowlistApprovesNoConfiguration,
            in: release
        ) {
            try self.allowlist(
                entries: try self.shape.candidates.indices.map { offset in
                    try self.entry(
                        offset,
                        gateEvidence: self.gateEvidence(
                            self.failingGate(offset),
                            outcome: .failed
                        )
                    )
                }
            )
        }

        // Requirement 13.19 rather than 13.22: something is distributable, so the finding
        // is about this device. The distributable entry is the extra sibling, which no
        // generated candidate collides with.
        await expectRefused(
            "a failing matched entry beside a distributable one",
            .unsatisfiedDeviceGates,
            in: release
        ) { [gate = failingGate(0)] in
            try self.allowlist(
                entries: try self.entries(
                    replacingMatched: try self.entry(
                        0,
                        gateEvidence: self.gateEvidence(gate, outcome: .failed)
                    )
                ) + [try self.extraSibling()]
            )
        }
    }

    // MARK: - Refusal helpers

    /// Requires `build` to refuse with a specific schema fault, recording an issue
    /// otherwise.
    ///
    /// Never rethrows. `propertyCheck` discards an error thrown by its body without
    /// recording an issue, so a refusal that escaped as a throw would make this property
    /// pass vacuously.
    func expectSchemaRefusal(
        _ what: String,
        _ expected: AllowlistSchemaFault,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> Void
    ) {
        do {
            try build()
            Issue.record("\(what) was accepted [\(shape)]", sourceLocation: sourceLocation)
        } catch let error as ArtifactSchemaError {
            #expect(
                AllowlistSchemaFault(error) == expected,
                "\(what) was refused as \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        } catch {
            Issue.record(
                "\(what) failed with a non-schema error \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Requires the startup gate to refuse the allowlist `build` returns, recording an
    /// issue otherwise.
    ///
    /// The coherent allowlist is registered again afterwards whatever happened, because
    /// the artifact store is shared for the whole case and an arm that left its mutation
    /// behind would silently change what the next arm tests.
    ///
    /// `reportedField` is asserted where a fault case is reached by more than one member
    /// of the version tuple: the Model Bundle and the Device Validation Plan both refuse
    /// as ``PreflightFailure/identityMismatch``, so the case alone would let one arm's
    /// refusal stand in for another's.
    ///
    /// Never rethrows, for the reason above.
    func expectRefused(
        _ what: String,
        _ expected: PreflightFault,
        reportedField: String? = nil,
        in release: BoundRelease,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ build: () throws -> ReleaseApprovedDeviceAllowlist
    ) async {
        let mutated: ReleaseApprovedDeviceAllowlist
        do {
            mutated = try build()
        } catch {
            Issue.record(
                "\(what) could not be built: \(error) [\(shape)]",
                sourceLocation: sourceLocation
            )
            return
        }

        await release.scenario.policies.register(mutated)
        var refusal: PreflightFailure?
        do {
            _ = try await release.scenario.run()
        } catch {
            refusal = error
        }
        await release.scenario.policies.register(release.coherentAllowlist)

        guard let refusal else {
            Issue.record("\(what) was admitted [\(shape)]", sourceLocation: sourceLocation)
            return
        }
        #expect(
            PreflightFault(refusal) == expected,
            "\(what) was refused as \(refusal) [\(shape)]",
            sourceLocation: sourceLocation
        )
        if let reportedField {
            #expect(
                PreflightFault.reportedField(refusal) == reportedField,
                "\(what) named \(PreflightFault.reportedField(refusal) ?? "no field") [\(shape)]",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Fault classification

/// Which ``ArtifactSchemaError`` a refusal reported, without its field strings.
///
/// Asserting the case rather than the whole value keeps the property about *why* an entry
/// was refused while leaving the audit message free to change. Asserting nothing about
/// the case would let an unrelated fault stand in for the one an arm is about.
private enum AllowlistSchemaFault: Equatable {
    case emptyValue
    case placeholderValue
    case noncanonicalValue
    case valueOutOfRange
    case nonPositiveValue
    case nonFiniteValue
    case duplicateEntry
    case missingRequiredEntries
    case unexpectedEntries
    case fixedValueMismatch
    case forbiddenValue
    case inconsistentReference

    init(_ error: ArtifactSchemaError) {
        switch error {
        case .emptyValue: self = .emptyValue
        case .placeholderValue: self = .placeholderValue
        case .noncanonicalValue: self = .noncanonicalValue
        case .valueOutOfRange: self = .valueOutOfRange
        case .nonPositiveValue: self = .nonPositiveValue
        case .nonFiniteValue: self = .nonFiniteValue
        case .duplicateEntry: self = .duplicateEntry
        case .missingRequiredEntries: self = .missingRequiredEntries
        case .unexpectedEntries: self = .unexpectedEntries
        case .fixedValueMismatch: self = .fixedValueMismatch
        case .forbiddenValue: self = .forbiddenValue
        case .inconsistentReference: self = .inconsistentReference
        }
    }
}

/// Which ``PreflightFailure`` a refusal reported, without its payload.
private enum PreflightFault: Equatable {
    case artifactUnavailable
    case allowlistApprovesNoConfiguration
    case deviceNotAllowlisted
    case unsatisfiedDeviceGates
    case identityMismatch
    case unapprovedArtifact
    case mixedAllowlistVersions
    case capabilitySetMismatch
    case provenanceLinkageMismatch
    case verifiedBundleUnavailable
    case startupCleanupFailed

    init(_ failure: PreflightFailure) {
        switch failure {
        case .artifactUnavailable: self = .artifactUnavailable
        case .allowlistApprovesNoConfiguration: self = .allowlistApprovesNoConfiguration
        case .deviceNotAllowlisted: self = .deviceNotAllowlisted
        case .unsatisfiedDeviceGates: self = .unsatisfiedDeviceGates
        case .identityMismatch: self = .identityMismatch
        case .unapprovedArtifact: self = .unapprovedArtifact
        case .mixedAllowlistVersions: self = .mixedAllowlistVersions
        case .capabilitySetMismatch: self = .capabilitySetMismatch
        case .provenanceLinkageMismatch: self = .provenanceLinkageMismatch
        case .verifiedBundleUnavailable: self = .verifiedBundleUnavailable
        case .startupCleanupFailed: self = .startupCleanupFailed
        }
    }

    /// The artifact field a refusal named, for the two cases that name one.
    static func reportedField(_ failure: PreflightFailure) -> String? {
        switch failure {
        case let .identityMismatch(field, _, _): field
        case let .mixedAllowlistVersions(field, _): field
        default: nil
        }
    }
}

// MARK: - Non-vacuity witness

/// Records what the generator actually produced, so the property cannot pass by
/// generating one fixed shape a hundred times.
///
/// A property whose baseline never varies asserts one example a hundred times over. This
/// collects the dimensions the arms depend on and requires each to have been exercised
/// with more than one value. The thresholds are far below what 100 uniform draws produce,
/// so this witnesses variation rather than pinning a distribution.
private final class DeviceAllowlistVariationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var seeds = Set<Int>()
    private var candidateCounts = Set<Int>()
    private var capabilitySets = Set<[String]>()
    private var provenanceDraws = Set<Bool>()
    private var fusionDraws = Set<Bool>()
    private var hardwareIdentifiers = Set<String>()
    private var osVersions = Set<String>()
    private var selectedGates = Set<String>()
    private var cases = 0

    func record(_ shape: AllowlistShape) {
        lock.lock()
        defer { lock.unlock() }
        cases += 1
        seeds.insert(shape.seed)
        candidateCounts.insert(shape.candidates.count)
        capabilitySets.insert(
            PreflightSample.capabilities(
                provenance: shape.provenanceEnabled,
                fusion: shape.fusionEnabled
            )
            .map(\.rawValue)
            .sorted()
        )
        provenanceDraws.insert(shape.provenanceEnabled)
        fusionDraws.insert(shape.fusionDraw)
        for (offset, candidate) in shape.candidates.enumerated() {
            hardwareIdentifiers.insert("iPhone\(17 + offset).\(candidate.hardwareMinor)")
            osVersions.insert("\(17 + offset).\(candidate.osMinor).\(candidate.osPatch)")
        }
        selectedGates.insert(shape.selectedGate.rawValue)
    }

    func expectVariedBaselines() {
        lock.lock()
        defer { lock.unlock() }

        #expect(cases >= 100, "the design requires at least 100 generated cases")
        // A constant baseline would show 1 in each of these.
        #expect(seeds.count >= 80, "generated seeds: \(seeds.count)")
        #expect(
            candidateCounts == [1, 2, 3],
            "generated candidate counts: \(candidateCounts.sorted())"
        )
        // Three, not four: fusion is derived from provenance, so the fourth combination
        // is a release that cannot exist. Both underlying draws are still witnessed, so a
        // generator that stopped varying one of them fails here rather than quietly
        // covering three sets with two.
        #expect(
            capabilitySets.count == 3,
            "generated capability sets: \(capabilitySets.sorted { $0.count < $1.count })"
        )
        #expect(provenanceDraws == [false, true], "both provenance settings are generated")
        #expect(fusionDraws == [false, true], "both fusion settings are generated")
        #expect(
            hardwareIdentifiers.count >= 20,
            "generated hardware identifiers: \(hardwareIdentifiers.count)"
        )
        #expect(osVersions.count >= 60, "generated operating-system versions: \(osVersions.count)")
        #expect(selectedGates.count >= 15, "generated selected gates: \(selectedGates.count)")
    }
}
