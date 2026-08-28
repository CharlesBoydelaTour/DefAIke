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
  Local.xcconfig.example      Template for local signing settings; copy is gitignored
  DefAIkePackage/            Every reusable module and its tests
  DefAIkeApp/                Main app target sources
    Shared/                   The app target's sources, including its one composition
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

## Running on your own iPhone

Full step-by-step version, with the failure diagnostics:
[ON_IPHONE_SETUP.md](../ON_IPHONE_SETUP.md). Summary below.

A Debug build installs and runs on a physical iPhone. It is a development build in
every sense: the device allowlist is derived from whatever device it observes, the
Model Bundle's activation receipt is fabricated, and the calibration is unapproved,
so the on-screen notice saying nothing below is a verdict about any image is the
literal truth. See `DevelopmentProvisioning.swift`.

**1. Add your Apple ID to Xcode.** Xcode → Settings → Accounts → **+** → Apple ID.
A free Apple ID appears as *Personal Team* and is enough to install on your own
device. Note the ten-character Team ID shown beside it.

**2. Enable Developer Mode on the iPhone.** Settings → Privacy & Security →
Developer Mode → on, then restart and confirm. (The entry appears only after a
development build has been installed once, or after Xcode has seen the device.)

**3. Set your team ID.** Edit `ios/Local.xcconfig`, which
`Scripts/generate-xcode-project.sh` creates for you from `Local.xcconfig.example`
and `.gitignore` excludes:

```
DEFAIKE_LOCAL_DEVELOPMENT_TEAM = ABCDE12345
```

Set it here rather than in Xcode's Signing & Capabilities tab: the `.xcodeproj` is
generated and not committed, so anything set in the UI is discarded the next time
the project is regenerated. Change `DEFAIKE_LOCAL_BUNDLE_PREFIX` in the same file
if `dev.defaike` collides with something already provisioned to your account — it
moves the app, the Share Extension, and the App Group together, which they need.

**4. Regenerate and run.**

```bash
ios/Scripts/generate-xcode-project.sh
open ios/DefAIke.xcworkspace
```

Select your iPhone as the destination and Run. A free-provisioned build expires
after seven days and needs reinstalling.

### What to expect, and the one thing that may block you

The pixel model **is** bundled: `ios/project.yml` names the tracked
`data/coreml/commfor-lowq-384.mlpackage` in the app target's Debug resource phase,
and Xcode's Core ML compiler puts `commfor-lowq-384.mlmodelc` in the app bundle.
Measured with Xcode 26.6, its `weights/weight.bin` is byte-identical to the
`RequiredPixelModel` digest the domain pins. So inference runs on device from the
app's own bundle, and a fresh clone on another machine needs no extra artifact.
A **Release** build carries no model, deliberately — see the note in `project.yml`.

The likely blocker is the **App Group**. Both the app and the Share Extension
declare `group.<prefix>.app`, and App Groups may not be provisionable with a free
Personal Team. If it is not, `SessionStorageRoots` cannot resolve the container and
startup refuses with `appGroupContainerUnresolvable` — which renders as a **blank
white screen**, because `StartupBlockedView` deliberately shows no unapproved text.
Confirm the cause rather than guessing:

```bash
xcrun devicectl list devices          # find your device
# then, with the app launched, watch the DEBUG diagnostic channel:
#   log stream --level debug --predicate 'subsystem == "dev.defaike.development"'
```

The refusal is logged at **debug** level, so `log show` will not display it —
`log stream --level debug` is required. The same blank screen appears for a
Simulator build made with `CODE_SIGNING_ALLOWED=NO`, for the same reason: no
entitlements blob, so no App Group.

If the App Group cannot be provisioned, the options are a paid Apple Developer
Program membership, or a DEBUG-only fallback to an app-private container — which
would disable the Share Extension handoff and weaken a deliberate fail-closed
guarantee, so it is not in the tree.

## Capability composition

One app, one signed build output, both evidence capabilities. Whether Content
Credential validation is *usable* is decided by signed artifacts and gates, never
by a remotely toggled feature flag:

| Composition | App target | Linked product | Provenance |
|---|---|---|---|
| Pixel plus provenance | `DefAIkeApp` | `DefAIkeAppKit` | Conditional C2PA adapter linked |

This replaces two build outputs — a pixel-only app that linked no validator and a
pixel-plus-provenance app that did — with one. The split existed so gate evidence
could not be pooled across capability sets (Requirements 13.18–13.22); with one
composition there is one capability set, so there is nothing to pool.

What that cost, stated because it is real: "the installed release cannot validate
Content Credentials" used to be a fact about the linked bytes, checkable with `nm`
on a shipped archive. The app links the adapter now, so keeping the validator
inactive is the job of `ProvenanceLaneProvider.resolve(...)`, the signed Release
Capability Manifest, and the startup gate — code and artifacts rather than
absence. The Share Extension is the remaining shipping bundle whose exclusion of
the validator can still be measured from outside the source, which is what keeps
the app's linkage measurement non-vacuous.

The provenance lane is still unavailable in every build today, and reports
`validatorEnablementUnapproved`: the adapter is linked and the manifest enables the
capability, and no approved decision supplies an analyzer. The two owed approvals
are enumerated in `UnresolvedProvenanceEnablement`.

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

# Compile the app against the iOS SDK.
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
