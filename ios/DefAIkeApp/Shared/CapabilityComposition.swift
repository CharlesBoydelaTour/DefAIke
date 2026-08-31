import DefAIkeDomain
import DefAIkeProvenanceAPI

/// The compile-time capability composition of one signed build output.
///
/// DefAIke ships one app, and `CompiledCapabilityComposition` is its composition: pixel
/// analysis and Content Credential validation from the same binary, never a remotely toggled
/// feature flag.
///
/// This protocol survives the collapse from two compositions to one, and not out of habit.
/// Keeping composition facts behind a protocol is what makes them *comparable*: the startup
/// gate's whole job is to check a build's compiled facts against a signed artifact, and a
/// generic seam is how the fidelity tests reach that check with compositions the shipping
/// target does not contain — a build that claims provenance without linking a validator, one
/// that links a validator without claiming it, one that attests a version its module graph
/// contradicts. Those shapes have to stay constructible somewhere, or the refusals for them
/// are untested (Requirements 6.19 and 6.20).
///
/// A compiled composition is not a release approval. `MainAppComposition.start(...)` compares
/// this value against the signed Release Capability Manifest and the version-bound device
/// allowlist entry during startup preflight, in both directions, and fails closed on any
/// mismatch (Requirements 6.2 and 6.3).
///
/// Every member here is a *compiled* fact. The per-capability implementation versions the gate
/// compares are still not among them: the gate requires set equality against the signed manifest,
/// and a source literal would be a version claim this repository cannot make, so those versions
/// arrive through `MainAppReleaseProvisioning` and are combined with these facts in one place.
///
/// `linkedImplementationVersions` is the one exception, and it is not that claim. It carries what
/// a *linked adapter module* reports about itself, so it exists only where the adapter does, and
/// its only use is to refuse a provisioned version the binary contradicts. It states which
/// release is linked; it never states which release is approved.
/// `Sendable` because a composition is a compile-time fact with no stored state: the conforming
/// types are caseless enums whose whole content is `static let`s. Requiring it lets the metatype
/// cross into the composition root's `async` startup without a concurrency exception.
protocol CapabilityComposition: Sendable {
    /// Stable identifier for this composition, recorded by the startup preflight and the
    /// release-readiness record.
    static var identifier: String { get }

    /// Whether a Content Credential validator is linked into this build output.
    static var linksProvenanceValidator: Bool { get }

    /// The capabilities this build compiles. Always includes pixel analysis, the required
    /// Version 1 evidence capability.
    ///
    /// Deliberately independent of `linksProvenanceValidator`: a composition that claims
    /// provenance without linking a validator, and one that links a validator without claiming
    /// provenance, are both representable and both fail preflight.
    static var capabilities: Set<CapabilityID> { get }

    /// This composition's provenance analyzer, or `nil` when it has none.
    ///
    /// `nil` is always an unavailable lane, and which reason it reports depends on
    /// ``linksProvenanceValidator`` rather than on this member alone: a build that links no
    /// adapter has none to supply, while a build that links one and still supplies `nil` has
    /// an adapter no approved decision lets it use
    /// (`ProvenanceLaneProvider.resolve(linksValidator:analyzer:policy:manifest:)`).
    ///
    /// The `store` is where ingest retained the exact encoded bytes; a validator inspects those
    /// and nothing else (Requirement 6.6). The `policy` is the signed Provenance Policy the
    /// session is bound to, present exactly when the manifest binds one.
    static func provenanceAnalyzer(
        store: any EphemeralFileStoring,
        policy: ProvenancePolicy?,
        copyCatalog: ApprovedVerdictCopyCatalog
    ) -> (any ProvenanceAnalyzing)?

    /// The implementation version each compiled capability's *linked module* reports about
    /// itself, keyed by capability, as the raw `major.minor.patch` text that module carries.
    ///
    /// This is the one member whose value a build output cannot state on its own: each entry
    /// has to be read from a constant inside the linked adapter, so the entry exists only in a
    /// composition whose module graph contains that adapter. A composition that does not link
    /// an adapter for a capability contributes no entry for it, and cannot.
    ///
    /// Why it is separate from ``capabilities`` and from the provisioned
    /// `[CapabilityImplementationEntry]`: the provisioned versions arrive from the release
    /// build through `MainAppReleaseProvisioning`, so on their own they are an *assertion about*
    /// the binary rather than a fact about it. Nothing stopped a build from declaring
    /// `content-credential-validation: 9.9.9` in Info.plist while linking the reviewed 0.0.12
    /// adapter, and the startup gate would have compared that assertion against a signed
    /// manifest carrying the same wrong number and found them equal.
    ///
    /// Every entry here is checked against the provisioned entry for the same capability by
    /// ``compiledComposition(implementationVersions:)`` before any comparison against the signed
    /// manifest happens, and a disagreement is a refusal. That is what makes "the
    /// provenance-enabled archive requires the exact approved adapter version" a property of the
    /// linked bytes rather than of a plist key.
    ///
    /// Raw text rather than `CapabilityImplementationVersion`, deliberately: a linked module's
    /// self-reported version is arbitrary text until something canonicalizes it, and a value
    /// that is not canonical must fail the comparison rather than fail to be constructed at the
    /// point of attestation. `SchemaSemanticVersion` already rejects `0.0.0` and every
    /// noncanonical form, so a noncanonical attestation can never equal a provisioned entry.
    static var linkedImplementationVersions: [CapabilityID: String] { get }
}

/// Why a compiled composition is not a runnable build.
///
/// None of these is a gate decision and none is an `AnalysisError`: each is a shape a coherent
/// module graph plus a coherent provisioned input set cannot have, so an inconsistent value is
/// refused before it can reach the comparison the startup gate makes against the signed
/// manifest.
///
/// Recorded as a value, in the same style as the other gap and refusal vocabularies, so a
/// release audit can read which one fired instead of being told only that the composition was
/// rejected. `CustomStringConvertible` for that audit surface; nothing here is user-facing copy.
/// `Error` for `Result`'s sake only, matching `PreflightFailure` and `UnprovisionedRelease`, which
/// are `Error` for the same reason. Nothing throws one, and nothing converts one into an
/// `AnalysisError`: a refused composition means no Analysis Session ever began.
enum CompositionInconsistency: Error, Hashable, Sendable, CustomStringConvertible {
    /// The composition identifier is not canonical artifact text.
    case compositionIdentifierNotCanonical(String)

    /// `DefAIkeDomain.CompiledCapabilityComposition` refused the capability set and version
    /// list: no pixel analysis, or a list that does not name each compiled capability exactly
    /// once.
    case capabilitiesAndVersionsIncoherent

    /// A linked adapter attests a version for a capability this composition does not compile.
    ///
    /// The module graph and the declared capability set disagree, which is exactly the
    /// disagreement the two are kept apart to make representable.
    case attestedCapabilityNotCompiled(capability: String)

    /// The provisioned implementation version for a capability is not the version its linked
    /// adapter reports.
    ///
    /// The provenance-enabled archive's adapter-version pin, refused. `linked` is read from the
    /// adapter inside this binary; `provisioned` came from the release build's input set.
    case linkedImplementationVersionMismatch(
        capability: String,
        linked: String,
        provisioned: String
    )

    var description: String {
        switch self {
        case let .compositionIdentifierNotCanonical(identifier):
            return "the composition identifier \(identifier) is not canonical artifact text"
        case .capabilitiesAndVersionsIncoherent:
            return """
                the compiled capability set and its implementation versions are not a coherent \
                module graph
                """
        case let .attestedCapabilityNotCompiled(capability):
            return """
                a linked adapter reports a version for \(capability), which this composition \
                does not compile
                """
        case let .linkedImplementationVersionMismatch(capability, linked, provisioned):
            return """
                the linked \(capability) adapter is version \(linked), but this build was \
                provisioned as \(provisioned)
                """
        }
    }
}

extension CapabilityComposition {
    /// The observed module-graph facts, combined with the provisioned implementation versions.
    ///
    /// Three refusals, in this order, and each one is a shape a real build cannot have:
    ///
    /// 1. Every capability a linked adapter attests must be one this composition compiles.
    /// 2. Every provisioned version for an attested capability must equal what that adapter
    ///    reports. This is the adapter-version pin, and it is checked here rather than at the
    ///    signed-manifest comparison because the manifest cannot see inside the binary.
    /// 3. The capability set and version list must be coherent, which
    ///    `DefAIkeDomain.CompiledCapabilityComposition` decides.
    ///
    /// A `failure` never reaches the gate's comparison, so the gate is never handed a
    /// composition whose stated versions its own module graph contradicts.
    static func compiledComposition(
        implementationVersions: [CapabilityImplementationEntry]
    ) -> Result<DefAIkeDomain.CompiledCapabilityComposition, CompositionInconsistency> {
        guard let compositionIdentifier = try? ArtifactText(validating: identifier) else {
            return .failure(.compositionIdentifierNotCanonical(identifier))
        }

        // 1 and 2. The linked adapters' own account of themselves, against the provisioned one.
        //
        // Sorted so a build with more than one disagreement always reports the same first
        // finding: an audit that reruns a refused build has to see the same cause twice.
        let attested = linkedImplementationVersions
            .sorted { $0.key.rawValue < $1.key.rawValue }
        for (capability, linked) in attested {
            guard capabilities.contains(capability) else {
                return .failure(.attestedCapabilityNotCompiled(capability: capability.rawValue))
            }
            guard let provisioned = implementationVersions
                .first(where: { $0.capability == capability })?
                .version
            else {
                // No provisioned entry for a compiled capability. Left to
                // `CompiledCapabilityComposition`, which refuses exactly this shape, so one
                // rule decides coverage rather than two.
                continue
            }
            guard provisioned.rawSchemaValue == linked else {
                return .failure(
                    .linkedImplementationVersionMismatch(
                        capability: capability.rawValue,
                        linked: linked,
                        provisioned: provisioned.rawSchemaValue
                    )
                )
            }
        }

        // 3. Module-qualified: each build output's own composition enum is also named
        // `CompiledCapabilityComposition`, and the unqualified name resolves to that one.
        guard let compiled = DefAIkeDomain.CompiledCapabilityComposition(
            compositionIdentifier: compositionIdentifier,
            capabilities: capabilities,
            implementationVersions: implementationVersions,
            linksContentCredentialValidator: linksProvenanceValidator
        ) else {
            return .failure(.capabilitiesAndVersionsIncoherent)
        }
        return .success(compiled)
    }
}
