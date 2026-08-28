# Implementation status

**Snapshot:** August 2026, at the end of the `ios-app` spec's implementation pass. Every numbered task and every checkpoint in the spec is marked complete. This page is a state ledger against what the last verification pass actually measured, not an aspirational summary.

## Headline numbers

| Metric | Value |
|---|---|
| Package tests | **2,905 passing, 0 failing** |
| Package test suites | **367** |
| Property-based tests | 40, all asserting non-vacuity by construction, not by timing alone |
| Debug build, `DefAIkeApp` scheme | Zero errors, for the simulator and with signing |
| Module-boundary check | Passes, including `--require-xcode-project` |
| Release-audit self-tests | 12/12, 5/5, 12/12, 6/6, 7/7, 16/16, 41/42, 28/28 probes fire as designed |
| App on Simulator (iPhone 17 Pro, iOS 26.5) | Startup gate passes; a Photos ingest completes and both lane cards render |

Every one of these numbers was measured by running the actual tools in `ios/Scripts/`, not inferred from source review.

Three qualifiers, stated rather than buried:

- **Release configuration, `build-for-testing`, and the repeat-run count were not re-measured** after the two capability compositions were merged into one. Earlier checkpoints recorded zero-error Release builds on both former schemes, a `build-for-testing` success on each, and four consecutive clean host runs; only the Debug simulator build and one host run were repeated after the merge.
- **`release-pipeline.py --self-test` fails one probe of 42.** `appBuild reason names the placeholder identity` expects the `0.0.0`/`0` build identity `PLACEHOLDER_BUILD_IDENTITY` names, and `project.yml` carries `0.1.0`/`1`. Pre-existing and unrelated to the merge — verified by stashing the merge and reproducing 41/42 on the prior commit. The gate's conclusion is right (no release-approved `AppBuildID` exists either way); only its stated reason is wrong.
- **`check-share-extension-target.py` has no self-test mode**, so seven scripts contribute the eight probe counts above. The final checkpoint verifier explicitly checked the vacuity-exclusion mechanism for every property test (all 40 closures contain zero propagating `try`, so the framework's `try?`-based error-discarding path has nothing to discard — vacuity is closed by the type system, not by convention) and spot-checked counted-work floors in the newest deterministic suites to rule out a loop that examines nothing but still reports a pass.

## What exists and passes

Every section of the spec has shipped code and tests, not a stub:

- **Domain foundations** — session values, versioned policy and release-artifact schemas, the closed port layer, and `DefAIkeTestSupport`'s fakes.
- **Release configuration and startup gates** — three-layer artifact decoding, `ReleaseConfiguration`, and the seven-step main-app `StartupPreflight`.
- **Photos and Share Extension ingest** — real `PhotosImportAdapter`/`PhotosIngestCoordinator`, and the real Share chain (`ShareExtensionIngestCoordinator` → `SharedTransferStore` → `ShareHandoffClaimAdapter` → `ShareHandoffIngestCoordinator`) across an App Group.
- **Defensive image validation and exact preprocessing** — container sniffing, complete decode, deterministic bilinear resize/crop matching the model's contract.
- **Model Bundle integrity, activation, and Core ML execution** — signature/digest/compatibility verification, self-test plumbing, and one-logit inference behind the domain port.
- **Calibration and release-evidence evaluation** — the three-label calibration evaluator and its release-slice metrics.
- **Conditional provenance, independent evidence lanes, and fusion** — the provenance port, the fusion-rule lookup, and the lane-independence guarantee.
- **Session orchestration, resource control, cancellation, and cleanup** — the `AnalysisCoordinator` actor, target-specific resource budgets, cooperative cancellation, and lifecycle-policy-driven cleanup.
- **Safe SwiftUI presentation, accessibility, and localization readiness** — view-state projection, evidence cards, the accessibility semantics layer, and the English String Catalog.
- **Main app and Share Extension compositions** — both composition roots, both `StartupPreflight`/`ShareExtensionStartupGate` fail-closed gates, and build-isolation enforcement between the application composition and the Share Extension.
- **Fixture, device, security, and release-validation automation** — the fixture catalog, parity/resource/accessibility-matrix runners, a Software Bill of Materials generator, corpus-identifier remediation tooling, and release-record assembly with device-allowlist generation.
- **Final wiring** — the noninteractive `release-pipeline.py`, deterministic composition-root tests, and fail-closed preflight integration tests.

## Known defects

These are real production defects surfaced by the test suite, deliberately left unfixed and pinned by a passing test that documents the actual behavior, because fixing them is a design decision outside an implementation pass. Each is reported here rather than silently worked around. One has since been fixed and is kept, struck through, with the account of what changed.

### ~~The provenance composition cannot complete a single Analysis Session~~ — fixed

**Fixed when the two capability compositions were merged into one.** It had to be: the single application composition links the validator, so its manifest enables provenance and *every* session in the shipping app would have failed.

The defect was this. No shipping type conforms to the domain's `ProvenanceAnalyzing` port — the C2PA adapter (`DefAIkeProvenanceC2PA.C2PAProvenanceValidator`) deliberately does not conform, and `c2pa-swift` 0.0.12 refuses to configure with synthetic trust anchors. `AnalysisSessionBinder` binds a Provenance Policy based on `admission.enablesProvenance`, read from the signed capability manifest, so a provenance-enabled build always bound one; the lane resolved from a `nil` analyzer reported none; and `EvidenceCoordinator.checkProvenanceAttribution` required the two to agree in both directions. Result: every session on both ingest routes failed with `AnalysisError.modelLoadError` at the evidence-joining stage.

Two things changed:

1. **`checkProvenanceAttribution` now permits an unavailable lane in a policy-bound session.** The refusal rested on an implication that no longer holds. While the pixel-only build linked no validator, an enabling manifest meant a linked adapter and `ProvenanceLaneProvider`'s enabled path always returns an available lane, so enabled implied available and the biconditional was free. One composition adds a break in that chain: linked, enabled, and no analyzer. The other direction stays hard — an available lane in a session bound to no policy, or naming a policy the session did not bind, is still refused.
2. **`UnavailableReason` gained `validatorEnablementUnapproved`.** Reporting the new state as `validatorNotCompiledIntoRelease` would misstate the module graph of a build that links the adapter, and as `capabilityNotEnabledByReleaseCapabilityManifest` would misstate the manifest. All three reasons resolve to the one approved `provenanceUnavailable` copy entry, so this needed no new approved wording — the distinction is for a release audit, not for a reader.

The binding was deliberately *not* derived from the resolved lane. It records which signed policy version governs the session, a configuration fact; deriving it from whether an analyzer happened to exist would make the same signed release record different bindings, which is the version-attribution property the binding exists to hold still.

Tests: `unavailableLaneIsPermittedBesideABoundPolicy`, `aProvenanceEnabledReportCompletesWithABoundPolicy`, `linkingIsNotApproval`.

### `StartupPreflight` admits evidence it should refuse

**Severity: blocking for release-record integrity, not for a running session.** Two distinct gaps, both measured live against the real gate:

1. `GateResultReference.isSatisfied` returns `decision.isApproved` for the `.notApplicable` case, and unlike `ReleaseGateRecord`, `GateResultReference` has no check that an *unconditional* gate cannot be declared not applicable. An `ApprovedDeviceConfiguration` with all 22 mandatory device gates waived constructs successfully and reports `unsatisfiedGates.isEmpty == true` — an entry in which nothing ever ran on a phone reports itself as fully satisfied, and `permitsDistribution` answers `true`.
2. `StartupPreflight`'s coherence check (`requireCoherentEntries`) compares only `fixtureSuite` and `validationPlan` across sibling allowlist entries — never `appBuild`. Two sibling entries can disagree about which application build they were validated against, and preflight admits the mismatched pair anyway.

Both were closed at the release-record assembly layer (a stricter, additional check there refuses both shapes), but the runtime preflight gate itself still admits them. The fix for the first needs a schema change to `GateResultReference` or `ApprovedDeviceConfiguration.init`; the fix for the second is `requireIdentity(tuple.appBuild, matches: manifest.appBuild)` inside `requireVersionTuple`.

### Requirement 2.2 (Share Extension visible consent) cannot be satisfied by any release today

The closed `VerdictCopySurface` vocabulary in `DefAIkeDomain` defines **no surface for any Share Extension text at all** — no consent-action label, no consent scope statement, no manual "open the app" instruction. The Share Extension's module closure also cannot reach `DefAIkePresentation`, so even an approved surface would need its own resolution path. Until the vocabulary is extended and wording is approved, the extension's consent screen has no words to show, and the extension renders no user-facing text rather than fabricating any — sixteen closed gap vocabularies across the codebase record exactly this class of blocker rather than filling it with a placeholder.

### Three mandatory device gates are unsatisfiable by construction, independent of the missing hardware

- `DeviceGate.screenshotFidelity` — `ComparisonMetric.screenshotGeometry` has no corresponding `FixtureExpectationKind`, so no approved expected value can ever be represented for it.
- `DeviceGate.cancellationResidualWork` and `.interruptionCleanup` — `DeviceValidationPlan.measurements` has no condition/phase dimension, so a condition-specific measurement cannot be predeclared at all, while Requirement 13.17 makes both gates mandatory regardless.

The generated device allowlist would stay empty even given an approved Device Validation Plan and a physical iPhone, because these three gates fail unconditionally. This is carried through the release record as `no-jointly-satisfiable-mandatory-device-gate-set-exists`.

### Smaller findings, pinned as tests rather than fixed

- `preservationStatus` on a Share-transferred asset is not integrity-bound to its payload: changing `preservationStatus` and `preservationBasis` together to another internally-coherent pair produces a record that decodes, resolves, and verifies — with an *upgraded* status reaching the Evidence Report even though nothing about the actual bytes changed.
- The input route (Photos picker vs. Share Extension) is absent from `EvidenceReport`, so two byte-identical sessions taken through the two different routes produce `==` reports.
- `AnalysisWorkPercentage.percent` is arithmetically inexact (integer division truncation); the shipping `WorkProgressReadout` the user actually sees computes its own exact value and is unaffected.
- No cancellation checkpoint exists between joining the two evidence lanes and committing the terminal report — a cancellation requested in that narrow window is not observed.
- No root `LICENSE`/`NOTICE` file and no `PrivacyInfo.xcprivacy` exist in the repository; both are measured as absent and reported as owed release-controlled inputs by `audit-release-archives.py`, not silently skipped.
- Nothing invokes `release-pipeline.py` automatically — there is no CI configured for this repository, so every audit above is manual-only today.

## Unverifiable in this environment

These are not defects; they are the honest boundary of what a development Mac with the iOS 26.5 SDK/simulator can establish, stated explicitly rather than implied:

- **No physical iPhone.** Every Device Validation Plan gate reports `not-executed` and is recorded as an owed release-controlled input. `ObservedParityEnvironment.current` — which every parity, resource, and accessibility-matrix runner consults — is compiled from `#if targetEnvironment(simulator)` with no setter, no injection point, and no override, so no host or simulator result can ever satisfy a physical-device gate. This is proven, not assumed: the test suite includes a deliberate contradiction where every observation *claims* to be from a physical iPhone and every measured cell passes, while every gate that depends on the process's own environment still fails.
- **Only the iOS 26.5 SDK and simulator runtime are installed.** Compilation at the iOS 17.0 deployment floor is verified on every target, in both architectures, Debug and Release. Runtime behavior at that floor cannot be verified here.
- **`PlatformDataProtection.enforcesDataProtection` is `false` off iOS**, so Requirement 9.6 (iOS Data Protection enforcement on ephemeral files) has no host evidence; the host suite exercises the fail-closed *code path* but not the platform guarantee itself.
- **No signed release artifacts exist.** Roughly fifteen release-controlled inputs remain owed: application build identity, capability manifest, capability implementation versions, Model Bundle, calibration policy, lifecycle policy, fixture suite, validation plan, a distribution archive, the first-party privacy manifest, physical-device execution evidence, a produced Initial Model Bundle artifact tree, approved notice artifacts, an approved binary-digest baseline, and an approved external-dependency allowlist artifact. Both evidence scopes the pipeline observes are marked provisional as a result.
- **No approved copy exists beyond three fixed pixel labels.** The English String Catalog ships with exactly the three required labels (`Signals consistent with AI generation`, `No strong signal detected`, `Not enough signal`); every other user-facing surface — privacy screens, model information, the correction channel, accessibility labels, Share Extension text — is a recorded, enumerable gap rather than an invented sentence.
- **The provenance composition's offline guarantee is runtime configuration, not code absence.** The vendored `C2PAC` static archive links a complete Rust HTTP/2 + TLS + async-runtime stack (measured: `h2`, `hyper`, `tokio`, `rustls`, `reqwest`, and more, all as lower bounds because this toolchain's `nm` cannot read every archive member) plus swift-certificates' OCSP client. Offline behavior is enforced by `C2PALibraryReader.applyOfflineSettings` (`remoteManifestFetch: false`, `ocspFetch: false`, `allowedNetworkHosts: []`) at runtime, not by the capability being absent from the binary. The Share Extension's guarantee is different in kind: its `.appex` images have **zero** network symbol references and **zero** URL-like strings once the code-signing DOCTYPE URL is excluded (a signed build embeds the entitlements plist, whose DOCTYPE names the property-list DTD; an unsigned build carries none), which is genuine absence — and since the two app compositions were merged into one, the extension is the absence case that keeps those scans non-vacuous. Neither audit script treats the application's network capability as a violation; both record it as a Provenance Feasibility Gate security-review input.

## Where the model-side evidence stands

This app bundles the checkpoint selected by the Phase 0 benchmark work, not a model this project trained. For that evidence — corpus, degradation protocol, model comparison, and the Core ML conversion/ANE gate — see [Shipping model card](../results/shipping-model.md), [Core ML deployment gate](../results/coreml.md), and [Limitations and next boundary](../project/limitations.md). Item 3 of that limitations list ("validate screenshot and preprocessing parity on physical iPhones") and item 4 ("measure score parity, latency, memory, power, and thermal behavior on target devices") are exactly the physical-device gates this app's release-validation tooling is built to run, once a device and a signed artifact set exist.

## Boundary before public release

Combining this page with [Limitations and next boundary](../project/limitations.md), a public release needs, at minimum:

1. a design decision resolving the provenance-composition session-completion defect;
2. a hardening pass on `StartupPreflight`'s two admission gaps;
3. an approved-copy decision extending `VerdictCopySurface` to cover Share Extension text, plus every other recorded copy gap;
4. either a Device Validation Plan schema change (to make the three unconditionally-failing gates satisfiable) or an accepted, documented device-allowlist scope that excludes them;
5. a physical iPhone and a signed release artifact set — manifest, allowlist, resource budgets, lifecycle policy, calibration policy, fixture suite, validation plan, fusion rule, and approved copy catalog;
6. resolution of the repository code-licence and dataset-distribution-rights items already tracked in [Limitations](../project/limitations.md#licensing-and-release-readiness).

None of these are implementation gaps in the sense of missing code — the code paths, tests, and fail-closed behavior for all six already exist. They are release-governance and evidence gaps that no amount of further Swift implementation closes by itself.
