# Loading DefAIke onto a physical iPhone

Written for an agent picking this up on another machine. Follow it in order. Every
command is meant to be run from the repository root, and every step has a
verification you can check before moving on.

Scope: getting a **Debug** build onto a physical iPhone with a free Apple ID
("Personal Team"). Nothing here produces release evidence — see
[What this build is not](#what-this-build-is-not) before you report any result
from it.

---

## 0. Preconditions

```bash
xcode-select -p                 # must point at /Applications/Xcode.app/Contents/Developer
xcodebuild -version             # measured working: Xcode 26.6
xcodegen --version              # measured working: 2.46.0; project.yml floor is 2.42.0
```

If `xcode-select -p` prints a CommandLineTools path, either switch it
(`sudo xcode-select -s /Applications/Xcode.app`) or prefix every Xcode command with
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

**The pixel model is already in the clone.** `.gitignore` tracks
`data/coreml/commfor-lowq-384.mlpackage` (42 MB, 3 files) and excludes only the
compiled `.mlmodelc`. Verify:

```bash
git ls-files data/coreml/ | wc -l          # expect 3
du -sh data/coreml/commfor-lowq-384.mlpackage   # expect ~42M
```

If that returns 0 files the clone is incomplete — do **not** try to work around it
by regenerating the model. The domain pins its weight digest
(`RequiredPixelModel.weightDigestHexadecimal`), so a differently-converted model is
a different model.

---

## 1. Add the Apple ID to Xcode

Xcode → Settings → Accounts → **+** → Apple ID → sign in.

A free account shows as **Personal Team**. Copy its ten-character Team ID from the
team list beside the account.

---

## 2. Enable Developer Mode on the iPhone

Unplug the phone first. Settings → Privacy & Security → **Developer Mode**
(bottom of the list) → on → restart → unlock → confirm **Turn On**.

The menu item only appears once the device has been attached to Xcode or has had a
development build installed. If you cannot find it, plug the phone in, let Xcode
finish "Preparing device", then look again.

Verify the Mac can see it:

```bash
xcrun devicectl list devices
```

Note the device's identifier column — later commands take it as `--device`.

---

## 3. Set the Team ID

`ios/Local.xcconfig` is gitignored and is created for you from
`ios/Local.xcconfig.example` by the generator. Create it if it is not there yet:

```bash
ios/Scripts/generate-xcode-project.sh    # prints a note if it seeds the file
```

Then edit `ios/Local.xcconfig`:

```
DEFAIKE_LOCAL_DEVELOPMENT_TEAM = ABCDE12345
DEFAIKE_LOCAL_BUNDLE_PREFIX = dev.defaike
```

**Set it here, not in Xcode's Signing & Capabilities tab.** `ios/DefAIke.xcodeproj`
is generated from `ios/project.yml` and is not committed, so anything set through
Xcode's UI is discarded the next time anyone regenerates the project.

Change `DEFAIKE_LOCAL_BUNDLE_PREFIX` only if `dev.defaike` collides with something
already provisioned to the account. It moves the app, the Share Extension, and the
App Group together — they must name the same App Group or the consented handoff has
no container to meet in. Note that a re-prefixed build then fails
`check-capability-composition.py`, which identifies an archive by its
`CFBundleIdentifier`; that is the audit working, not a regression.

---

## 4. Regenerate and run

```bash
ios/Scripts/generate-xcode-project.sh
open ios/DefAIke.xcworkspace
```

In Xcode: scheme **DefAIkeApp**, destination = the iPhone, then Run.

Running from Xcode is strongly preferred over installing a build by hand, because
Xcode's console pane is the only convenient place to read the app's `os.Logger`
output — see [Diagnosing a blank screen](#diagnosing-a-blank-screen).

If you must install without Xcode:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild build -workspace ios/DefAIke.xcworkspace -scheme DefAIkeApp \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/defaike-device
xcrun devicectl device install app --device <DEVICE> \
  /tmp/defaike-device/Build/Products/Debug-iphoneos/DefAIke.app
xcrun devicectl device process launch --device <DEVICE> --terminate-existing \
  dev.defaike.app
```

**Never pass `CODE_SIGNING_ALLOWED=NO`.** It strips the entitlements blob, which
removes the App Group, which makes the app refuse startup with a blank screen. This
has already cost debugging time once; see the table below.

A free-provisioned build stops launching after **seven days**. Reinstall to renew.

---

## 5. Verify

Expected on first launch:

1. A yellow banner: *"Development build. Its calibration is not approved, so nothing
   below is a verdict about any image."*
2. A centred viewfinder glyph.
3. A pinned button at the bottom: **Choose an image to analyze**.

Then tap the button, pick any photo, and expect a completed report with **two
cards**:

- a pixel lane card — one of `Signals consistent with AI generation`,
  `No strong signal detected`, or `Not enough signal`, with its qualifying paragraph;
- a provenance lane card reading *"This version cannot check Content Credentials.
  That is a limit of the installed app, not a finding about the image."*

Below them: a **What this cannot tell you** disclosure row and an **Information**
navigation row.

Both cards must be present. The provenance card saying the release cannot check
Content Credentials is **correct and expected** — the C2PA validator is compiled in
but no approved decision supplies an analyzer. That is not a bug to fix here.

### Not yet verified on device

An end-to-end analysis completing **from the bundled model** has not been observed
on a physical device or on the Simulator since the model was moved into the app
bundle. Simulator UI automation was broken in the session that made the change
(WebDriverAgent kept backgrounding the app), so this is the first thing to check.

What *was* measured, and is safe to rely on:

| Fact | Value |
|---|---|
| Debug bundle contains the compiled model | `commfor-lowq-384.mlmodelc` at the bundle root |
| Its `weights/weight.bin` SHA-256 | `f073f8a325f63e35ef0668c985ac762486a1b50e57dcf5ae33d4647bd26d4c1e` |
| Same digest in the working tree and in `RequiredPixelModel` | yes, all three identical |
| Release bundle contains a model | no — excluded by `EXCLUDED_SOURCE_FILE_NAMES` |

To confirm the model reached a device build:

```bash
ls /tmp/defaike-device/Build/Products/Debug-iphoneos/DefAIke.app/ | grep mlmodelc
shasum -a 256 /tmp/defaike-device/Build/Products/Debug-iphoneos/DefAIke.app/\
commfor-lowq-384.mlmodelc/weights/weight.bin
```

---

## Diagnosing a blank screen

A white screen with nothing on it is **not a crash and not a hang**. It is
`StartupBlockedView`, which renders `Color.clear` on purpose: no approved copy
exists for a startup refusal, and the design refuses to put unapproved words on
screen. The cause is carried two ways instead.

### Route A — the accessibility identifier (no logging needed)

The blank element's accessibility identifier names the cause:

```
defaike.startup.pending.<composition>                  # gate still running
defaike.startup.blocked.<composition>.<cause>          # gate refused
```

Read it with Xcode → Open Developer Tool → Accessibility Inspector, targeting the
device. `<composition>` is `pixel-plus-provenance`. The complete set of `<cause>`
tokens, from `ios/DefAIkeApp/Shared/StartupBlockedView.swift`:

```
app-group-container-unresolvable      composition-identifier-not-canonical
approved-copy-unreadable              linked-implementation-version-mismatch
attested-capability-not-compiled      preflight-refused
calibration-policy-not-activatable    release-inputs-unprovisioned
composition-not-runnable              resource-controller-not-bindable
device-identity-unobservable          session-store-not-configurable
```

`app-group-container-unresolvable` is the one to expect on a Personal Team build.
`preflight-refused` collapses every gate failure into one token, so it is the case
where Route B below is worth the extra effort — the log carries the specific
`PreflightFailure` and the identifier does not.

### Route B — the DEBUG diagnostic channel

The refusal's full description is written through `os.Logger` at **debug** level.
That matters:

- **Xcode's console pane** shows it when you Run from Xcode. Easiest route.
- **Console.app** works too: select the device, filter on subsystem
  `dev.defaike.development`, and turn on Action → **Include Debug Messages**.
  Without that, debug-level messages are not displayed.
- `devicectl device process launch --console` will **not** show it. That attaches
  stdout/stderr; this output goes to the unified log.
- On the Simulator the equivalent is:
  ```bash
  xcrun simctl spawn booted log stream --level debug \
    --predicate 'subsystem == "dev.defaike.development"'
  ```
  `log show` does not persist debug-level messages — `--level debug` on `log stream`
  is required.

### Causes, in order of likelihood

| Symptom | Cause | Fix |
|---|---|---|
| Blank screen; log says `appGroupContainerUnresolvable` | The App Group is not provisioned for this build | See [The App Group blocker](#the-app-group-blocker) |
| Blank screen after a `CODE_SIGNING_ALLOWED=NO` build | No entitlements blob, so no App Group | Rebuild with signing; an ad-hoc simulator signature is enough |
| Blank screen; log says `releaseInputsUnprovisioned` | A Release build, or the Debug Info.plist substitutions did not resolve | Confirm the configuration is Debug and `ios/project.yml`'s Debug `DEFAIKE_*` keys are present |
| Blank screen; log says `deviceIdentityUnobservable` | `DefAIkeAppBuildID` missing from the built Info.plist | Regenerate the project; do not hand-edit the plist |
| Ready screen appears, then picking a photo gives an error screen with `model-load-error` | The compiled model is not in the bundle | Check the `ls`/`shasum` commands above; confirm `../data/coreml/commfor-lowq-384.mlpackage` is still in the app target's Debug sources in `ios/project.yml` |

---

## The App Group blocker

Both the app and the Share Extension declare `group.<prefix>.app`, and
`SessionStorageRoots` fails closed if the container cannot be resolved — falling
back to a process-private directory would leave session material somewhere the
lifecycle policy does not own, so it deliberately does not.

**App Groups may not be provisionable with a free Personal Team.** This has not been
confirmed against a real free account in this repository; treat it as the most
likely obstacle rather than a settled fact, and confirm from the log before
concluding anything.

If it cannot be provisioned, the options are:

1. A paid Apple Developer Program membership. Cleanest; changes no code.
2. A DEBUG-only fallback to an app-private container. This would disable the Share
   Extension handoff and weaken a deliberate fail-closed guarantee, so it is **not**
   in the tree. Do not add it without saying plainly that that is what you are
   doing.

Do not "fix" this by removing the App Group entitlement — the Share Extension's
whole handoff protocol addresses that container.

---

## Known-flaky tooling

- **Simulator UI automation** (`mobile_click_on_screen_at_coordinates` and
  friends) failed repeatedly with *"timed out waiting for WebDriverAgent to be
  ready"*, and each failed attempt sent the app to the background — so a tap
  sequence would then land on the home screen instead of the app. If a tap
  "succeeds" but the next screenshot shows the home screen, that is what happened.
  Relaunch the app and retry; a failed attempt often warms WDA for the next one.
- **`codesign -d --entitlements -`** on a simulator `.app` may report *"bundle
  format unrecognized, invalid, or unsuitable"* even for a correctly signed bundle.
  Empty output from that command is a reliable signal of *no* entitlements; an error
  from it is not a reliable signal of anything.

---

## What this build is not

Every one of these is deliberate and documented in
`ios/DefAIkeApp/Shared/DevelopmentProvisioning.swift`. Do not report a result from
this build as evidence for any of them.

- **Not release evidence.** The device allowlist is derived from whatever device the
  app observes, rather than authored before the device was seen.
- **Not a verified Model Bundle.** The activation receipt reports `.passed` for a
  signature nobody checked and a self-test nobody ran. Artifact digests are fixed
  patterns, not measurements.
- **Not an approved calibration.** The on-screen banner saying nothing below is a
  verdict about any image is the literal truth.
- **Not physical-device gate evidence.** Requirement 13.16 admits only results
  produced under an approved Device Validation Plan on an allowlisted
  configuration. A build installed this way satisfies neither.
- **Not Content Credential validation.** The C2PA validator is linked and the
  manifest enables the capability; no approved decision supplies an analyzer, so the
  lane reports `validatorEnablementUnapproved`. See `UnresolvedProvenanceEnablement`
  for the two owed approvals.

---

## Related documents

- [ios/README.md](ios/README.md) — module layout, capability composition, build and
  test commands
- [docs/ios-app/build-and-test.md](docs/ios-app/build-and-test.md) — every script
  and its self-test modes
- [docs/ios-app/status.md](docs/ios-app/status.md) — measured numbers and the
  current known-defect ledger
- [docs/ios/index.md](docs/ios/index.md) — verified state, toolchain, and the
  boundaries of what has been established
