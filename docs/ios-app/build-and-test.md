# Build, test, and release tooling

Everything in this page runs from the `ios/` directory unless stated otherwise. Two verification levels exist and they answer different questions: **host** results (Swift Testing on the development Mac) prove module correctness; **iOS build** results (Xcode/`xcodebuild`) prove the app and extension compile against the iOS SDK. Neither is physical-device evidence, and no device gate can be satisfied by either — see [Implementation status](status.md#unverifiable-in-this-environment).

## Tooling requirements

| Tool | Needed for | Note |
|---|---|---|
| Swift 6.1+ toolchain | `host-test.sh`, boundary check | Command Line Tools is enough |
| XcodeGen 2.42+ | `generate-xcode-project.sh` | `brew install xcodegen` |
| Xcode | `build-ios.sh`, `xcodebuild`, simulator/device runs | Command Line Tools has no iOS SDK |
| Python 3 + PyYAML | `check-module-boundaries.py`, the release-audit scripts | Provided by the repository dev environment (`.venv`) |

The `.xcodeproj` is generated rather than committed, so the target graph stays reviewable as one declarative spec in `project.yml`. Run `generate-xcode-project.sh` before opening the workspace on a fresh clone, or whenever `project.yml` changes. **XcodeGen cannot regenerate the project without picking up every declared setting** — if you hand-patch `project.pbxproj` for any reason, keep `project.yml` consistent with the patch, because a future regeneration will otherwise silently revert it.

If Xcode is not the active developer directory:

```bash
sudo xcode-select --switch /Applications/Xcode.app
```

## Generate the project

```bash
ios/Scripts/generate-xcode-project.sh
```

Runs XcodeGen against `project.yml`, then reports whether Xcode is active. Open `ios/DefAIke.xcworkspace` afterward — not the `.xcodeproj` directly, since the workspace is what ties the generated project to the SwiftPM package.

## Host tests

```bash
ios/Scripts/host-test.sh
```

Builds all three SwiftPM products (`DefAIkeAppKit`, `DefAIkeShareExtensionKit`, `DefAIkeReleaseValidation`) and runs the whole package test suite with `swift test`. This is the fastest, most complete correctness check and the one to run after any Swift change. It does not compile the Xcode-only app/extension/UI/device-validation targets — those require `build-ios.sh`.

The script supplies Swift Testing's framework and interop search paths explicitly when Xcode is not the active developer directory, since the Command Line Tools install of `Testing.framework` lacks the paths SwiftPM passes when Xcode is active.

Property tests in this suite are real generative tests (via `swift-property-based`), not fast no-op placeholders — expect the full run to take roughly a minute and a half, with individual property tests running from under a second to under a minute each depending on case count.

## iOS build

```bash
ios/Scripts/build-ios.sh
```

Compiles the `DefAIkeApp` scheme for `generic/platform=iOS Simulator` with `CODE_SIGNING_ALLOWED=NO`, Debug configuration. Requires Xcode. It builds into the default derived-data path; the release-audit scripts below want a dedicated `-derivedDataPath` so a stale bundle from another build cannot be inspected by mistake.

For a Release build, or to keep an archive in its own products directory for the audit scripts, invoke `xcodebuild` directly with a dedicated derived-data path:

```bash
xcodebuild build \
  -workspace ios/DefAIke.xcworkspace \
  -scheme DefAIkeApp \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/pixelonly \
  CODE_SIGNING_ALLOWED=NO
```

Release has `SWIFT_TREAT_WARNINGS_AS_ERRORS` and `GCC_TREAT_WARNINGS_AS_ERRORS` on, so it is a stricter check than Debug.

To compile the UI and device-validation test bundles without running them (`build-for-testing`), `CODE_SIGNING_ALLOWED=NO` is likewise required — without it both un-hosted bundles fail with a missing-Info.plist code-signing error, since neither target has one to sign.

## Module boundary check

```bash
.venv/bin/python ios/Scripts/check-module-boundaries.py --require-xcode-project
```

Reads `swift package dump-package` and the Xcode project spec, and fails closed on any of ten rules: every design module exists; `DefAIkeDomain` has no dependencies; the Share Extension composition cannot reach inference, image-pipeline, model-bundle, provenance, application, or release-validation code; the application composition links `DefAIkeProvenanceC2PA` and no retired per-capability product or target has returned; `DefAIkeReleaseValidation` is absent from every shipping composition; `swift-property-based` is exact-pinned and test-only; `DefAIkeTestSupport` belongs to no product and is used by at least one test target; the declared iOS minimum is 17.0 everywhere; one app target and one Share Extension target exist sharing one App Group; no Xcode target links a module its role forbids; and, with `--require-xcode-project`, every generated target resolves to iPhone-only (Xcode's per-target presets can silently override a project-level device-family setting, so the generated result is checked directly rather than only the spec).

Requires PyYAML (`uv pip install -e ".[docs]"` in the repository dev environment provides it).

## Release-audit scripts

Four Python scripts under `ios/Scripts/` audit the built archives for evidence a compile check cannot produce. Each is layered on the ones before it — later scripts run earlier scripts and ingest their `--json` output rather than re-deriving the same facts, so there is exactly one authority per measurement.

| Script | Owns | Depends on |
|---|---|---|
| `check-share-extension-target.py` | The `.appex`: declared dependency set, comment-stripped source scan, and (with `--products`) forbidden frameworks/symbols/bundled model artifacts in the built extension | — |
| `check-capability-composition.py` | Adapter version-pin coherence across four locations, the closed five-package external-dependency allowlist, a 219-file production-source scan for six forbidden dependency classes, both targets' `Info.plist`/entitlements, and per-composition archive self-attribution via `CFBundleIdentifier` | — |
| `check-offline-privacy-archive.py` | Per-compiled-object symbol attribution over *every* object file in the build (not just whole-module blobs), the app/Share-Extension network-symbol split, an archive endpoint inventory, and a seventh forbidden class: result persistence and export | Runs both scripts above |
| `audit-release-archives.py` | A CycloneDX 1.6 Software Bill of Materials for the composition, revision-level dependency reconciliation, binary-artifact digests, total module-to-package attribution, and a typed release-record input for `DefAIkeReleaseValidation` to consume | Runs `check-offline-privacy-archive.py` (which runs the two above) |

Each script needs the built products, so build the scheme into its own derived-data directory first:

```bash
xcodebuild build -workspace ios/DefAIke.xcworkspace -scheme DefAIkeApp \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/defaike CODE_SIGNING_ALLOWED=NO

ios/Scripts/check-share-extension-target.py \
  --products /tmp/defaike/Build/Products/Debug-iphonesimulator

ios/Scripts/check-capability-composition.py \
  --products /tmp/defaike/Build/Products/Debug-iphonesimulator \
  --expect pixel-plus-provenance

ios/Scripts/check-offline-privacy-archive.py \
  --build /tmp/defaike --json /tmp/offline.json

ios/Scripts/audit-release-archives.py \
  --build /tmp/defaike \
  --sbom-directory /tmp/sbom --json /tmp/audit.json --release-input /tmp/release-input.json
```

`check-offline-privacy-archive.py` and `audit-release-archives.py` require a **Debug** build root specifically — they read `Build/Products/Debug-iphonesimulator` and `Intermediates.noindex/**/Objects-normal/<arch>/`.

Each script has one or more self-test modes that plant a real violation and require the check to fire, rather than trusting a script that has only ever reported zero findings:

```bash
ios/Scripts/check-capability-composition.py --self-test
ios/Scripts/check-capability-composition.py --self-test-products
ios/Scripts/check-offline-privacy-archive.py --self-test
ios/Scripts/check-offline-privacy-archive.py --self-test-products
ios/Scripts/audit-release-archives.py --self-test
ios/Scripts/audit-release-archives.py --self-test-archives
```

`audit-release-archives.py` **legitimately exits 1** on a real checkout today: no root `LICENSE`/`NOTICE` file, no `PrivacyInfo.xcprivacy` in either target, and no Model Bundle artifact embedded in either archive are all reported as findings and owed release-controlled inputs, not as tool failures. An exit-1 result from that script is expected, correct behavior, not a broken check.

## Noninteractive release pipeline

```bash
ios/Scripts/release-pipeline.py
```

Wires the checks above into one command with a fixed, screened command-line policy: every `xcodebuild` invocation it issues is restricted to compile-only actions (`build`, `build-for-testing`), always with a generic simulator destination and `CODE_SIGNING_ALLOWED=NO`, and is screened against a list of forbidden tokens (`test`, `archive`, provisioning-update flags, a concrete device destination, re-enabled signing) before it runs — so the pipeline itself cannot deploy anything or select an approval on the release's behalf.

Stages: toolchain check, evidence-scope observation, module-boundary check, host suite, Debug build, Release build, `build-for-testing`, device/UI-suite reporting (always `not-executed` — there is no physical device), the four archive audits, and validation of any supplied release artifacts.

```bash
ios/Scripts/release-pipeline.py --self-test              # 42 non-vacuity probes
ios/Scripts/release-pipeline.py --self-test-commands      # 28 command-safety probes
ios/Scripts/release-pipeline.py --print-plan              # print every command, run none of them
ios/Scripts/release-pipeline.py --stages toolchain,identity,build-debug,build-release
```

The full run **legitimately exits 1**: owed release-controlled inputs, a provisional evidence scope (both shipping targets currently record build identity `0`/`0.0.0`, which is a placeholder, not a release version), and unexecuted device gates. This is the correct current state — see [Implementation status](status.md).

## Every command in one place

```bash
# Generate the Xcode project (run once, and after any project.yml change)
ios/Scripts/generate-xcode-project.sh

# Fast correctness loop: host build + full test suite
ios/Scripts/host-test.sh

# Enforce module and target boundaries
.venv/bin/python ios/Scripts/check-module-boundaries.py --require-xcode-project

# Compile the app against the iOS SDK (Debug, simulator)
ios/Scripts/build-ios.sh

# Full noninteractive pipeline: builds, boundary check, host suite, archive audits
ios/Scripts/release-pipeline.py
```

## Known project quirks

**The device-validation bundle is an un-hosted logic bundle.** `DefAIkeDeviceValidationTests` sets `TEST_HOST: ""` with `TEST_TARGET_NAME` pointing at the app target, rather than a real hosted path. XcodeGen otherwise injects `TEST_HOST = $(BUILT_PRODUCTS_DIR)/DefAIkeApp.app/DefAIkeApp`, and the app target overrides `PRODUCT_NAME` to `DefAIke`, so that path never exists and build-for-testing fails with "Could not find test host". `$(PRODUCT_NAME)` cannot be substituted either: inside a test target it is the test bundle's own name. Hosting it for real would mean spelling `DefAIke.app` literally and coupling this target to the app's `PRODUCT_NAME`, which has not been done. Consequence: a device-validation test cannot observe in-app behavior today, only whatever it can reach as a standalone logic bundle linked against `DefAIkeReleaseValidation`.

(A second reason applied while two app targets built the same `DefAIke.app`: any `TEST_HOST` path matched both, so implicit-dependency resolution pulled both into one graph and the build failed with `Multiple commands produce .../DefAIke.app`. That reason went away with the second target; the `PRODUCT_NAME` reason did not.)

**Both compositions share `PRODUCT_NAME: DefAIke`.** This is also why every archive-audit script above needs a per-scheme `-derivedDataPath` and why `check-share-extension-target.py`/`check-capability-composition.py` require an explicit `--expect` cross-check against the archive's own `CFBundleIdentifier` rather than trusting the invocation.

**Local build identifiers are development values, not a release claim.** `dev.defaike.app`, `group.dev.defaike.app`, version `0.0.0`, and an empty `DEVELOPMENT_TEAM` are all placeholders `project.yml` documents explicitly. No script or test treats them as a shipping identity.

For everything these tools currently report — pass counts, known defects, and what remains unverifiable without a physical device and a signed release artifact set — see [Implementation status](status.md).
