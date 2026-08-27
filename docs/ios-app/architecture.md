# Architecture and modules

The app is a ports-and-adapters design around a pure domain core. Release-controlled values — device allowlists, resource budgets, cleanup deadlines, calibration boundaries, provenance trust, fusion mappings, approved copy — are represented as versioned artifacts the domain validates, not as constants or UI conditionals. A build is distributable only when every applicable release gate has one coherent, passing evidence set; nothing in the code chooses those values.

## Repository layout

```
ios/
  DefAIke.xcworkspace/       Entry point (open this)
  DefAIke.xcodeproj/         Generated from project.yml; not hand-edited
  project.yml                 Xcode target graph (XcodeGen spec)
  DefAIkePackage/            Every reusable module and its tests (SwiftPM)
    Sources/                  Eleven modules, listed below
    Tests/                    One test target per module
  DefAIkeApp/                Main app target sources
    Shared/                   Compiled into both compositions
    PixelOnly/                Pixel-only composition's own composition root
    PixelPlusProvenance/      Pixel-plus-provenance composition's own composition root
    Support/                  Info.plist, entitlements
  DefAIkeShareExtension/     Share Extension target sources
    Sources/                  Extension composition root, consent, startup gate
    Support/                  Info.plist, entitlements
  Tests/                      Xcode-only UI and physical-device test targets
    DefAIkeUITests/
    DefAIkeDeviceValidationTests/
  Scripts/                    Generation, build, test, and release-audit tooling
```

`DefAIkeApp/` and `DefAIkeShareExtension/` are Xcode-target sources, not SwiftPM targets — they cannot be imported by package tests and are compiled only through the generated Xcode project.

## Module graph

| Module | Ships in | Dependency rule |
|---|---|---|
| `DefAIkeDomain` | Both compositions + extension | No target dependencies. Foundation only where unavoidable |
| `DefAIkeSharedTransfer` | Both compositions + extension | `DefAIkeDomain` |
| `DefAIkeApplication` | Both compositions | `DefAIkeDomain`, `DefAIkeProvenanceAPI` |
| `DefAIkeImagePipeline` | Both compositions | `DefAIkeDomain` + Image I/O, Core Graphics |
| `DefAIkeModelBundle` | Both compositions + release tests | `DefAIkeDomain` |
| `DefAIkeCoreML` | Both compositions | `DefAIkeDomain` + Core ML |
| `DefAIkeProvenanceAPI` | Both compositions | `DefAIkeDomain`; defines the port, no vendor library |
| `DefAIkeProvenanceC2PA` | Pixel-plus-provenance only | `DefAIkeDomain`, `DefAIkeProvenanceAPI`, `c2pa-swift` (exact 0.0.12) |
| `DefAIkePresentation` | Both compositions | `DefAIkeDomain` + SwiftUI |
| `DefAIkeReleaseValidation` | Nonshipping | `DefAIkeDomain`, `DefAIkeModelBundle` |
| `DefAIkeTestSupport` | Nonshipping, test-only | `DefAIkeDomain`; belongs to no product |

Three products are built from this graph:

- **`DefAIkePixelOnly`** — the eight shared modules, no provenance adapter.
- **`DefAIkePixelPlusProvenance`** — the same eight modules plus `DefAIkeProvenanceC2PA`.
- **`DefAIkeShareExtensionKit`** — `DefAIkeDomain` + `DefAIkeSharedTransfer` only. No inference, image-pipeline, model-bundle, or provenance module is reachable from it; the Extension Execution Policy and `check-module-boundaries.py` both enforce this.

`DefAIkeReleaseValidation` and `DefAIkeTestSupport` are linked by test targets only and are unreachable from every shipping product — enforced by the same boundary check.

The application ports live in `DefAIkeDomain` rather than in `DefAIkeApplication`, so every adapter depends on the domain instead of on the orchestrator. That is what keeps `DefAIkeSharedTransfer` shippable inside the Share Extension without dragging in inference code.

## Domain core

`DefAIkeDomain` has four areas:

- **`Core/`** — session identity, evidence types, terminal outcomes, the closed ten-value `AnalysisError` vocabulary, and the state machines that arbitrate cancellation and faults.
- **`Calibration/`** — `CalibrationEvaluator`, the release-slice metrics the Calibration Policy is validated against, and calibration release approval.
- **`Fusion/`** — the deterministic Evidence Fusion Rule lookup: an optional, fixture-tested mapping from every combination of source-lane states to one Combined Summary, never a computed synthesis.
- **`Ports/`** — every application port an adapter implements.
- **`ReleaseArtifacts/`** — the versioned schema for every artifact a release binds: capability manifest, device allowlist, resource budgets, lifecycle policy, calibration policy, model bundle manifest, provenance policy, fusion rule, fixture suite, device validation plan, approved copy catalog, and the release readiness record that joins them.

### Ports and test doubles

`DefAIkeDomain/Ports/` holds the port protocols an adapter implements: Photos import, Share staging and claiming, input validation, preprocessing, model load, inference, calibration, provenance, fusion, bundle management, resource governance, cleanup, clock, ephemeral file store, and the runtime-policy and release-evidence readers.

Every analysis port uses typed `throws(AnalysisFault)`, so the closed `AnalysisError` vocabulary plus cancellation is a compile-time guarantee: an adapter cannot leak a raw framework error out of a port. Deliberately absent from every port: any timeout, deadline, or maximum-duration member; any way to raise or waive a resource limit; any model discovery, download, or update-check member; any default, fallback, or synthesized artifact value.

`DefAIkeTestSupport` holds bounded in-memory fakes and one shared call spy so domain and application behavior can be exercised without PhotosUI, Image I/O, Core ML, C2PA, the real file system, or a physical device. It belongs to no product, so it cannot be linked into any shipping executable — the boundary check fails if a product reaches it, if a shipping module depends on it, or if no test target uses it. Its digest helper is a real SHA-256 so byte-identity and mutation assertions actually bite; shipping adapters use CryptoKit. A double is never release evidence.

## Application orchestration

`DefAIkeApplication` is one actor, `AnalysisCoordinator`, plus its collaborators:

| File | Responsibility |
|---|---|
| `AnalysisCoordinator.swift` | The session actor: binds artifacts, runs ordered stages, commits exactly one terminal outcome |
| `EvidenceCoordinator.swift` / `EvidenceLaneJoin.swift` | Keep the pixel and provenance lanes independent until join time |
| `ApprovedEvidenceBranchExecution.swift` | Runs the pixel and provenance branches, serial or concurrent per the bound validation plan |
| `CausalFaultArbitration.swift` | Normalizes competing faults to one terminal error per stage, keeping the causally earliest |
| `ApparentInconsistencyClassifier.swift` | Detects when the two lanes disagree, without resolving the disagreement |
| `SessionCancellation.swift` | Cooperative cancellation and stale-callback suppression |
| `SessionTerminalCommit.swift` / `SessionTerminalCleanup.swift` | Commits the single terminal outcome; removes session material under the bound Data Lifecycle Policy |
| `ResourceController.swift` / `ResourceEnforcement.swift` | Applies the target-specific Resource Budget; a breach returns `resource-limit` with no evidence |
| `ProgressDerivation.swift` / `ProgressMeasurement.swift` | Honest, determinate-only-when-measured progress |
| `PhotosIngestCoordinator.swift` / `ShareHandoffIngestCoordinator.swift` | The two ingest routes into a bound session |

The coordinator's single terminal outcome is one of: a completed `EvidenceReport`, a `cancelled` state, or exactly one `AnalysisError`. There is no fourth shape.

## Platform adapters

| Module | Adapts |
|---|---|
| `DefAIkeImagePipeline` | Container sniffing, complete decode, RGB/color/alpha handling, deterministic bilinear resize to 440 px short edge and 384×384 center crop |
| `DefAIkeModelBundle` | Bundle parsing, canonicalization, signature/digest/compatibility verification, self-tests, activation, rollback |
| `DefAIkeCoreML` | `MLModel` loading and one-logit inference behind the domain's inference port |
| `DefAIkeProvenanceAPI` | The provenance port and result-mapping contract; no vendor code |
| `DefAIkeProvenanceC2PA` | The exact-pinned C2PA adapter, reachable only from the provenance composition |
| `DefAIkeSharedTransfer` | Photos and Share Extension ingest, App Group transfer, streaming hash/copy, protected ephemeral storage, session-data deletion |

## Presentation

`DefAIkePresentation` depends on `DefAIkeDomain` alone — not on `DefAIkeApplication` — so it can only render domain-typed snapshots, never reach the coordinator directly. It has six areas: `Models/` and `ViewState/` (the projected screen values), `Report/` (evidence cards, limitations, technical details), `Disclosure/` (privacy, model information, correction channel), `Copy/` (the Approved Verdict Copy binding), `Accessibility/` (the accessibility semantics layer, projected as plain data independent of displayed English), and `Resources/` (the English String Catalog).

The English String Catalog is carried as a real resource (`.copy`, not `.process`) so a release-validation tool can read and verify its bytes at runtime under both build systems. A localized-string lookup that misses returns the key rather than a placeholder sentence, and the presentation layer forbids ever showing a raw key to a user — a missing approved value is a release-validation failure, not a fallback string.

## Release validation

`DefAIkeReleaseValidation` is nonshipping tooling, present only in test and tool targets, covering:

- **Fixtures** (`FixtureCatalog*.swift`) — the immutable, versioned fixture suite and its expected-result schemas.
- **Parity** (`ParityValidation*.swift`) — comparing preprocessing output, raw logits, and categorical outcomes against the bound plan and fixtures on a physical device.
- **Resource and interruption evidence** (`ResourceValidation*.swift`) — main-app and Share Extension resource, cancellation, and interruption measurement, kept per-target.
- **Accessibility and localization matrix** (`AccessibilityMatrixValidation.swift`) — per-configuration workflow coverage over the approved iPhone allowlist.
- **Bundle creation** (`InitialModelBundleBuild*.swift`, `BundleBuild*.swift`) — reproducible Initial Model Bundle assembly and its own verification.
- **Corpus remediation** (`CorpusRemediation*.swift`) — the approved correction mapping for known dataset identifier collisions.
- **Archive audit** (`ArchiveAudit*.swift`) — SBOM ingestion, notice, corpus, and privacy findings, joined from the Python audit scripts below.
- **Release record** (`ReleaseRecordAssembly.swift`, `ReleaseRecordInputs.swift`) — the signed-record payload that joins calibration, bundle, privacy, archive, accessibility, localization, legal, governance, device, fixture, and capability evidence, and generates device allowlist entries only for exact, coherent, passing tuples.

Every one of these fails closed: a missing artifact, a missing physical-device result, or a version mismatch is a blocking finding, never a default or a warning level.

## Artifact decoding and release configuration

Reading a signed artifact happens in three layers that fail closed separately, so an audit can name one cause:

| Layer | Type | Fault |
|---|---|---|
| Bytes | `ArtifactEncodingProfile` / `BoundedArtifactDecoder` | `ArtifactDecodingError` |
| One artifact | each `ReleaseArtifacts` schema | `ArtifactSchemaError` |
| The set | `ReleaseConfiguration` | `ArtifactSchemaError.inconsistentReference` |

`ArtifactEncodingProfile` validates the payload in one pass before anything is allocated per field: payload ceiling, UTF-8 validity, duplicate object keys, nesting depth, and container/string/number ceilings. Duplicate keys are the reason it exists — a general-purpose decoder resolves them silently, so the same signed bytes could otherwise read as two different artifacts and the signature would stop pinning behavior.

`ReleaseConfiguration` is the validated join of every policy artifact one build binds. Every reference has to resolve to the artifact that carries that identifier, so an incoherent set is unrepresentable. `ReleaseConfiguration.load` takes the capability manifest identifier and derives every other identifier from that one signed manifest, reading conditional artifacts (provenance policy, fusion rule) only when the manifest binds them.

Bundle verification, device allowlisting, resource-plan completeness, and release readiness are separate, later gates. Nothing in this artifact layer approves a device, a bundle, or a distribution by itself.

## Composition roots

Two composition roots assemble the whole graph for one target, and each is the single call site for the fail-closed startup gate that admits it.

### Main app — `ios/DefAIkeApp/Shared/`

| File | Role |
|---|---|
| `CapabilityComposition.swift` | Protocol both `PixelOnly/` and `PixelPlusProvenance/` implement: which capabilities this build links and its self-reported implementation versions |
| `MainAppReleaseProvisioning.swift` | The release-controlled input set the composition root needs (capability manifest, allowlist, policies) |
| `MainAppComposition.swift` | `MainAppComposition.start(composition:provisioning:bundle:)` — runs the seven-step `StartupPreflight` gate, and is the only place that constructs an admitted app graph |
| `MainAppPlatform.swift` | Photos-picker and file-system platform glue |
| `MainAppScene.swift` | `MainAppModel`, the SwiftUI scene, and the coordinator-to-presentation snapshot bridge |
| `StartupBlockedView.swift` | The screen shown when the startup gate refuses admission |

`StartupPreflight` (in `DefAIkeDomain/ReleaseArtifacts/StartupPreflight.swift`) produces a `ReleaseAdmission` value whose initializer is `fileprivate` with exactly one call site, reached only after every gate step passes. Holding one *is* the evidence that the seven steps succeeded; there is no other way to obtain a session binder.

### Share Extension — `ios/DefAIkeShareExtension/Sources/`

| File | Role |
|---|---|
| `ShareExtensionModuleClosure.swift` | Documents and pins the extension's module closure — Domain + SharedTransfer only |
| `ShareExtensionReleaseProvisioning.swift` | The extension's own release-controlled input set |
| `ShareExtensionStartupGate.swift` | The extension's separate, eight-step preflight, producing a `ShareExtensionAdmission` |
| `ShareExtensionComposition.swift` | `ShareExtensionComposition.start(...)` — the extension's one admission call site |
| `ShareConsentPresenter.swift` / `ShareOutcomePresentation.swift` | The visible, user-consented handoff UI |
| `ShareViewController.swift` | The extension's principal view controller |

The Share Extension has no accessibility semantics layer of its own — it cannot reach `DefAIkePresentation`, and the closed `VerdictCopySurface` vocabulary in the domain currently defines no surface for any Share Extension text at all, which blocks its consent screen from having release-approved wording. See [Implementation status](status.md#known-defects).

## Test targets

| Target | Package | Subject |
|---|---|---|
| `DefAIkeDomainTests` | SwiftPM | Domain core, property tests |
| `DefAIkeApplicationTests` | SwiftPM | Coordinator, cross-module analysis-flow tests, offline/privacy smoke tests |
| `DefAIkeImagePipelineTests` | SwiftPM | Decode, resize, crop geometry |
| `DefAIkeModelBundleTests` | SwiftPM | Bundle verification, activation, rollback |
| `DefAIkeCoreMLTests` | SwiftPM | Inference contract |
| `DefAIkeProvenanceAPITests` / `DefAIkeProvenanceC2PATests` | SwiftPM | Provenance port and adapter |
| `DefAIkePresentationTests` | SwiftPM | View-state projection, accessibility, localization readiness |
| `DefAIkeSharedTransferTests` | SwiftPM | Ingest, App Group transfer, protected storage |
| `DefAIkeReleaseValidationTests` | SwiftPM | Fixtures, parity, resource, matrix, and release-record validation |
| `DefAIkeTestSupportTests` | SwiftPM | The fakes themselves |
| `DefAIkeUITests-<composition>` | Xcode | UI automation, per composition |
| `DefAIkeDeviceValidationTests-<composition>` | Xcode | Physical-device parity and resource gates, per composition; currently un-hosted logic bundles (see [Build and test](build-and-test.md#known-project-quirks)) |

For the current pass/fail state of every test target, see [Implementation status](status.md).
