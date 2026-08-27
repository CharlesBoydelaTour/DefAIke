# DefAIke iOS app

Swift implementation of the `ios-app` spec: an iPhone-only, iOS 17-or-later app
that evaluates one supported static image for evidence consistent with
whole-image AI generation.

**Current state:** domain foundations. Every module exists with its boundary and
dependency rule enforced. The domain carries its core session values, versioned
policy and release-artifact schemas, and the application ports plus test-only
doubles for them. No adapter is implemented yet: no ingest route, no image
pipeline, no inference, no provenance validator, no approved copy. This is spec
tasks 1.1 through 1.4.

## Layout

```
ios/
  DefAIke.xcworkspace/       Entry point (open this)
  project.yml                 Xcode target graph; the .xcodeproj is generated
  DefAIkePackage/            Every reusable module and its tests
  DefAIkeApp/                Main app target sources
    Shared/                   Compiled into both compositions
    PixelOnly/                Pixel-only composition
    PixelPlusProvenance/      Pixel-plus-provenance composition
  DefAIkeShareExtension/     Share Extension target sources
  Tests/                      Xcode-only UI and physical-device test targets
  Scripts/                    Generation, host test, iOS build, boundary check
```

## Modules

| Module | Ships in | Dependency rule |
|---|---|---|
| `DefAIkeDomain` | App + extension | No target dependencies. Foundation only where unavoidable |
| `DefAIkeSharedTransfer` | App + extension | `DefAIkeDomain` |
| `DefAIkeApplication` | App | `DefAIkeDomain`, `DefAIkeProvenanceAPI` |
| `DefAIkeImagePipeline` | App | `DefAIkeDomain` + Apple imaging frameworks |
| `DefAIkeModelBundle` | App + release tests | `DefAIkeDomain` |
| `DefAIkeCoreML` | App | `DefAIkeDomain` + Core ML |
| `DefAIkeProvenanceAPI` | App | `DefAIkeDomain`; no vendor provenance library |
| `DefAIkeProvenanceC2PA` | Provenance build only | `DefAIkeDomain`, `DefAIkeProvenanceAPI` |
| `DefAIkePresentation` | App | `DefAIkeDomain` + SwiftUI |
| `DefAIkeReleaseValidation` | Nonshipping | `DefAIkeDomain`, `DefAIkeModelBundle` |
| `DefAIkeTestSupport` | Nonshipping, test-only | `DefAIkeDomain`; in no product |

The application ports live in `DefAIkeDomain`, so every adapter depends on the
domain rather than on the orchestrator. That keeps `DefAIkeSharedTransfer`
shippable inside the Share Extension without dragging in inference code.

## Ports and test doubles

`DefAIkeDomain/Ports/` holds every application port an adapter implements: Photos
import, Share staging and claiming, input validation, preprocessing, model load,
inference, calibration, provenance, fusion, bundle management, resource governance,
cleanup, clock, ephemeral file store, and the runtime-policy and release-evidence
readers. Each analysis port uses typed `throws(AnalysisFault)`, so the closed
ten-value `AnalysisError` vocabulary plus cancellation is a compile-time guarantee:
an adapter cannot leak a framework error out of a port.

Deliberately absent from every port: any timeout, deadline, or maximum-duration
member; any way to raise or waive a resource limit; any model discovery, download,
or update-check member; any default, fallback, or synthesized artifact.

`DefAIkeTestSupport` holds bounded in-memory fakes and one shared call spy so
domain behavior can be exercised without PhotosUI, Image I/O, Core ML, C2PA, the
file system, or a physical device. It belongs to no product, so it cannot be
linked into any shipping executable; the boundary check fails if a product reaches
it, if a shipping module depends on it, or if no test target uses it. Its digest
helper is a real SHA-256 so byte-identity and mutation assertions actually bite;
shipping adapters use CryptoKit. A double is never release evidence.

## Artifact decoding and release configuration

Reading an approved artifact happens in three layers, and they fail closed separately
so an audit can name one cause:

| Layer | Type | Fault |
|---|---|---|
| Bytes | `ArtifactEncodingProfile` / `BoundedArtifactDecoder` | `ArtifactDecodingError` |
| One artifact | each `ReleaseArtifacts` schema | `ArtifactSchemaError` |
| The set | `ReleaseConfiguration` | `ArtifactSchemaError.inconsistentReference` |

`ArtifactEncodingProfile` validates the payload in one pass before anything is
allocated per field: payload ceiling, UTF-8 validity, duplicate object keys, nesting
depth, and container, string, and number ceilings. Duplicate keys are the reason it
exists — a general-purpose decoder resolves them silently, so the same signed bytes can
read as two different artifacts and the signature stops pinning behavior.

The payload ceiling has no default. `ArtifactEncodingLimits` cannot be constructed
without one, and `BoundedArtifactDecoder(manifestLimitsFrom:)` takes it from the
approved Bundle Verification Policy. The remaining bounds are structural safety
ceilings, not release values.

`ReleaseConfiguration` is the validated join of the policy artifacts one build binds.
Every reference has to resolve to the artifact that carries that identifier, so an
incoherent set is unrepresentable. `ReleaseConfiguration.load` takes the capability
manifest identifier and derives every other identifier from that signed manifest, and
reads the conditional artifacts only when the manifest binds them. Its accessors
(`signatureAlgorithm`, `trustedKey`, `cleanupDeadline`, `hardLimit`,
`manifestDecodingLimits`) are the single path to each governed value, and each one
starts at an artifact.

Bundle verification, device allowlisting, resource-plan completeness, and release
readiness are separate gates in later tasks. Nothing in this layer approves a device, a
bundle, or a distribution.

## Capability compositions

Two separate signed build outputs from the same source, never a remotely toggled
feature flag:

| Composition | App target | Linked product | Provenance |
|---|---|---|---|
| Pixel-only | `DefAIkeApp-PixelOnly` | `DefAIkePixelOnly` | Unavailable lane; no validator linked |
| Pixel plus provenance | `DefAIkeApp-PixelPlusProvenance` | `DefAIkePixelPlusProvenance` | Conditional C2PA adapter linked |

Each composition has its own Share Extension, bundle identifier, App Group, UI
test target, and device-validation target, so two installed builds cannot share a
handoff slot and gate evidence can never be pooled across capability sets.

Whether a Content Credential validator exists is a fact about the linked module
graph, checked at compile time. Linking the adapter is not approval to enable the
capability: the Provenance Feasibility Gate and an exact match against the signed
Release Capability Manifest are separate, later gates.

## Build and test

```bash
# Host: build every composition product and run unit and property tests.
ios/Scripts/host-test.sh

# Enforce the module and target boundaries.
.venv/bin/python ios/Scripts/check-module-boundaries.py --require-xcode-project

# Generate the Xcode project, then open ios/DefAIke.xcworkspace.
ios/Scripts/generate-xcode-project.sh

# Compile both compositions against the iOS SDK.
ios/Scripts/build-ios.sh
```

Host and simulator results are development checks. They are never physical-device
release evidence.

## Tooling requirements

| Tool | Needed for | Note |
|---|---|---|
| Swift 6.1+ toolchain | `host-test.sh`, boundary check | Command Line Tools is enough |
| XcodeGen 2.42+ | `generate-xcode-project.sh` | `brew install xcodegen` |
| Xcode | `build-ios.sh`, simulator, device runs | Command Line Tools has no iOS SDK |
| PyYAML | boundary check | Provided by the repository dev environment |

The `.xcodeproj` is generated rather than committed so the target graph stays
reviewable as one declarative spec. Run the generation script before opening the
workspace on a fresh clone.

## Dependencies

| Dependency | Version | Scope |
|---|---|---|
| [swift-property-based](https://github.com/x-sheep/swift-property-based) | exact 2.0.0 | Test targets only; never linked into a shipping executable |

No other external dependency exists. The domain and the test doubles are Foundation
only, so nothing in the port layer or the fakes pulls in a third-party library.

`c2pa-swift` 0.0.12 is **not** declared yet. Task 9.2 adds it to
`DefAIkeProvenanceC2PA` only, and it stays behind the Provenance Feasibility
Gate (implementation feasibility, correctness fixtures, resource limits, security
and dependency review, and physical-device validation).

## Deliberately unresolved

These stay external, versioned, approved inputs. The skeleton contains no
placeholder default for any of them, and code that needs one fails closed:

- the device allowlist and every approved iPhone configuration;
- resource budgets, cleanup deadlines, and analysis-time limits;
- calibration boundaries beyond the fixed constraints in the requirements;
- provenance trust, revocation, signer, and assertion policy;
- fusion mappings and approved verdict copy;
- signing key policy, distributed build identity, and export-compliance
  declaration;
- legal, data-rights, and governance conclusions.

The local build identifiers (`dev.defaike.app`, `group.dev.defaike.app`,
version `0.0.0`, empty `DEVELOPMENT_TEAM`) are development values, not a release
identity claim.
