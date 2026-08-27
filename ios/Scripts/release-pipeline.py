#!/usr/bin/env python3
"""The noninteractive build-and-validation entry point for both release compositions.

Task 15.1. Checkpoint 13 recorded the gap this closes: five verification scripts exist,
all of them pass or fail for good reasons, and **nothing runs any of them**. There is no
CI. Every audit in this repository is manual-only, which means every audit will silently
stop being run. This script is the one command that runs all of them, in a fixed order,
over builds it produced itself, and reports one exit status.

    ios/Scripts/release-pipeline.py                 # everything, into a temporary run directory
    ios/Scripts/release-pipeline.py --run-directory DIR
    ios/Scripts/release-pipeline.py --stages identity,module-boundaries
    ios/Scripts/release-pipeline.py --release-artifacts DIR   # also validate supplied artifacts
    ios/Scripts/release-pipeline.py --self-test              # non-vacuity validation
    ios/Scripts/release-pipeline.py --self-test-commands     # command-line safety validation
    ios/Scripts/release-pipeline.py --print-plan             # the commands, without running them

Why a driver script and not a new `.xcscheme`
---------------------------------------------

The task's own framing allowed either. This is a script, and every reason is a property
of the thing that had to be delivered rather than a preference:

1. **The blocker three separate tasks flagged is not expressible in a scheme.** Both app
   schemes build `DefAIke.app` under a shared `PRODUCT_NAME` into whatever derived-data
   directory the *invocation* names, so building both schemes back to back overwrites the
   first archive and leaves exactly one inspectable. `-derivedDataPath` is a per-invocation
   argument; a scheme has no such field. The archive audits (12.3, 12.5, 14.6) each need
   both archives to exist simultaneously, so only an invocation-level thing can fix this.
2. **`ios/DefAIke.xcodeproj/` is declared a generated artifact and is gitignored**
   (`ios/.gitignore:2`), and XcodeGen is not installed here, so `project.yml` cannot be
   regenerated. A scheme added only under `DefAIke.xcodeproj/xcshareddata/xcschemes/`
   would live in an ignored directory — it is not durable source. A scheme added only to
   `project.yml` would be declared and would not exist. Neither half can be made whole in
   this environment, so a new scheme is either invisible or a lie.
3. **A scheme cannot express the noninteractive constraints this task is mostly about.**
   `CODE_SIGNING_ALLOWED=NO`, a generic destination, offline package resolution, sequencing
   four Python audits, refusing to run when a release artifact is missing, and binding
   every emitted file to a version tuple are all outside a scheme's vocabulary. Xcode
   scheme pre-actions can shell out, but they run inside Xcode as hidden side effects,
   which is the opposite of an auditable entry point.
4. **The two existing schemes are already correct and are used unchanged.** This script
   drives `DefAIkeApp-PixelOnly` and `DefAIkeApp-PixelPlusProvenance` exactly as
   `project.yml` declares them. No `.xcscheme` file, no `project.pbxproj`, no `project.yml`,
   and no `Package.swift` edit was needed or made, so `build-ios.sh`, `host-test.sh`, and
   all five checks are untouched and keep working.

What "noninteractive, without deploying or selecting external approval values" means here
------------------------------------------------------------------------------------------

Two separate prohibitions, enforced two separate ways.

*No deployment.* Every `xcodebuild` invocation is constructed by `XcodebuildInvocation`,
which is the only place in this file that can produce an `xcodebuild` argument list. It
emits only the `build` and `build-for-testing` actions, always with
`-destination generic/platform=iOS Simulator`, always with `CODE_SIGNING_ALLOWED=NO`, and
always with its own `-derivedDataPath`. `FORBIDDEN_COMMAND_TOKENS` names what may never
appear — `test`, `test-without-building`, `install`, `archive`, `-allowProvisioningUpdates`,
`simctl`, a concrete `-destination` naming `name=`/`id=`, anything re-enabling signing — and
every invocation is screened against it before it runs, not merely when self-tested.
Nothing boots a simulator, installs, or launches. `--self-test-commands` proves the screen
is not vacuous by running it over planted bad command lines.

Running the two on-device XCTest bundles would require a concrete `-destination`, a booted
simulator, an install, and a launch, so this pipeline **compiles** them with
`build-for-testing` and reports their execution as `not-executed`. There is no physical
device, `ObservedParityEnvironment.current` is compiled from the target environment with no
setter, and simulator evidence cannot satisfy a device gate — so `not-executed` is the only
honest value and the pipeline cannot be argued into a different one.

*No approval selection.* This script contains no threshold, tolerance, limit, key, team
identifier, signing policy, allowlist entry, governance decision, or version choice. It
resolves package versions only from `Package.resolved`
(`-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution
-skipPackageUpdates`), which is also why it makes no network request. Where a release-
controlled input is required and absent, the pipeline records it as **owed** and the gate
that needs it is `failed`. Owed is never `passed`, and `not-executed` never satisfies a gate
either. That is 14.6's shape, deliberately: the pipeline reports what is owed; it does not
supply it.

Evidence binding: one tuple per run, and two tuples cannot be joined
--------------------------------------------------------------------

`ValidationVersionTuple` (`DefAIkeDomain/ReleaseArtifacts/ApprovedDeviceAllowlist.swift`)
is the identity Requirements 13.17 through 13.22 bind evidence to: app build, Model Bundle,
fixture suite, validation plan, capability manifest, capability set, and the per-capability
implementation versions. `EvidenceScope` here is the *observed* counterpart: each field is
either resolved from a measurable source in the working tree, with that source named, or
recorded as unresolved with the reason. `scopeDigest` is SHA-256 over the canonical JSON of
the whole thing, resolved and unresolved fields alike.

Every artifact this pipeline writes carries the full `evidenceScope` and its digest, and
the run directory is named by that digest. Joining is refused rather than avoided: whenever
the pipeline reads a JSON artifact that carries an `evidenceScope`, `require_joinable`
compares the *entire* scope field by field and refuses on any difference.

That refusal is deliberately whole-tuple. Task 14.9 found that `ParityRunBinding` never
reconciles `capabilityImplementationVersions`, so two tuples differing only in an
implementation version bind — the clause is enforced only per-observation, by whole-tuple
equality inside `QualifyingParityEvidence`. Task 14.8 is closing that at record level. This
pipeline does not depend on either: `require_joinable` compares
`capabilityImplementationVersions` like every other field, and `--self-test` includes the
exact 14.9 case — two scopes differing only in the provenance implementation version — as a
must-refuse.

**Every artifact this pipeline emits today is provisional, and says so in its own bytes.**
Both shipping targets record `CURRENT_PROJECT_VERSION: "0"` and `MARKETING_VERSION: "0.0.0"`
(`project.yml:60-61`), which are placeholders, not a build identity. So there is no
legitimate `AppBuildID`, the observed tuple can never be complete, and no artifact here can
be bound to a release version. `EvidenceScope.isProvisional` is true whenever any field is
unresolved, `PLACEHOLDER_BUILD_IDENTITY` records why the app build is one of them, and the
pipeline refuses to emit a non-provisional artifact while that is the case. The same fact is
already recorded by 14.6's audit as `audited-artifacts-are-not-distribution-artifacts`.

Deliberately out of scope
-------------------------

This script re-derives nothing the five existing checks own. It does not scan a source file,
read a Mach-O symbol table, digest a shipped byte, or parse an `Info.plist` for a forbidden
key: 12.2, 12.3, 12.5, and 14.6 own those and are *run*, with their `--json` outputs
collected as this run's evidence. It writes no SBOM of its own — it asks 14.6 for one. It
does not modify, re-implement, or second-guess `check-module-boundaries.py`.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

IOS = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = IOS / "Scripts"
WORKSPACE = IOS / "DefAIke.xcworkspace"
XCODE_PROJECT = IOS / "DefAIke.xcodeproj"
PROJECT_YML = IOS / "project.yml"
PACKAGE_DIR = IOS / "DefAIkePackage"
PACKAGE_SWIFT = PACKAGE_DIR / "Package.swift"
PACKAGE_RESOLVED = PACKAGE_DIR / "Package.resolved"

# `xcode-select -p` points at the Command Line Tools install on this machine and cannot be
# changed without sudo. Every Xcode tool therefore needs DEVELOPER_DIR set explicitly, and a
# pipeline that silently ran against the CLT install would report "no iOS SDK" as a build
# failure. So the developer directory is a checked precondition, not an assumption.
XCODE_DEVELOPER_DIR = pathlib.Path("/Applications/Xcode.app/Contents/Developer")

# The one destination that compiles for iOS without naming, booting, or installing onto a
# device or simulator. A concrete destination is what turns a build into a deployment.
GENERIC_SIMULATOR_DESTINATION = "generic/platform=iOS Simulator"

# Requirement 10.20 and 10.21: verification and activation happen with connectivity
# disabled, and no network query for an update is issued. A pipeline that re-resolved a
# package would both make a network request and *select a version*, which is an approval
# decision. All three flags together mean the only versions used are the ones
# `Package.resolved` already records.
OFFLINE_PACKAGE_FLAGS = [
    "-onlyUsePackageVersionsFromResolvedFile",
    "-disableAutomaticPackageResolution",
    "-skipPackageUpdates",
]

# `project.yml:60-61`. Not a release version claim, as the spec comment there says.
PLACEHOLDER_BUILD_IDENTITY = {"CURRENT_PROJECT_VERSION": "0", "MARKETING_VERSION": "0.0.0"}


# MARK: - Compositions

@dataclasses.dataclass(frozen=True)
class Composition:
    """One capability composition, named exactly as `project.yml` declares it."""

    name: str
    scheme: str
    bundle_identifier: str
    capabilities: tuple[str, ...]
    # 12.3's `--expect` value: a cross-check against the archive's own CFBundleIdentifier,
    # never the source of truth for what the archive is.
    expect: str


COMPOSITIONS = (
    Composition(
        name="pixel-only",
        scheme="DefAIkeApp-PixelOnly",
        bundle_identifier="dev.defaike.app",
        capabilities=("pixel-analysis", "share-extension-handoff"),
        expect="pixel-only",
    ),
    Composition(
        name="pixel-plus-provenance",
        scheme="DefAIkeApp-PixelPlusProvenance",
        bundle_identifier="dev.defaike.app.provenance",
        capabilities=(
            "pixel-analysis",
            "share-extension-handoff",
            "content-credential-validation",
        ),
        expect="pixel-plus-provenance",
    ),
)


# MARK: - Command-line safety

# What may never appear in an `xcodebuild` argument list this script builds. Each entry is
# one way to deploy, to boot something, to sign something, or to let a build pick a version
# on the release's behalf.
FORBIDDEN_COMMAND_TOKENS: tuple[tuple[str, str], ...] = (
    ("test", "runs a test bundle, which requires booting and installing onto a destination"),
    ("test-without-building", "runs a test bundle on a booted destination"),
    ("install", "installs a built product"),
    ("install-src", "installs sources"),
    ("archive", "produces a distribution archive, which is a release action"),
    ("-allowProvisioningUpdates", "contacts Apple and mutates signing assets"),
    ("-allowProvisioningDeviceRegistration", "registers a device with Apple"),
    ("-exportArchive", "exports a distribution archive"),
    ("-exportOptionsPlist", "supplies distribution options"),
    ("-authenticationKeyPath", "supplies an App Store Connect key"),
    ("-skipPackageSignatureValidation", "disables a package signature check"),
    ("-skipPackagePluginValidation", "disables a package plugin check"),
    ("simctl", "boots, installs onto, or launches on a simulator"),
    ("-resolvePackageDependencies", "re-resolves packages, which needs the network"),
)

# A `-destination` value naming a concrete simulator or device. `generic/platform=` is the
# only permitted shape, so anything carrying an `id=`, `name=`, or `udid=` selector is a
# deployment target rather than a compilation target.
CONCRETE_DESTINATION_SELECTORS = ("name=", "id=", "udid=")

# Settings that would re-enable signing after `CODE_SIGNING_ALLOWED=NO`, in any of the
# spellings `xcodebuild` accepts on the command line.
SIGNING_REENABLING_SETTINGS = (
    "CODE_SIGNING_ALLOWED=YES",
    "CODE_SIGNING_REQUIRED=YES",
    "CODE_SIGN_IDENTITY=",
    "DEVELOPMENT_TEAM=",
    "PROVISIONING_PROFILE",
    "CODE_SIGN_STYLE=Manual",
)


def command_line_violations(argv: list[str]) -> list[str]:
    """Every reason this argument list is not a noninteractive, non-deploying build.

    Deliberately a pure function over the argument list. The screen runs on every real
    invocation *and* over planted bad command lines in `--self-test-commands`, so the same
    predicate produces the guarantee and the evidence that the guarantee is not vacuous.

    Token matching is exact per argument rather than a substring search: `install` must not
    fire on `-derivedDataPath /tmp/install-x`, and `archive` must not fire on
    `audit-release-archives.py`. The two settings families are checked by prefix instead,
    because `CODE_SIGN_IDENTITY=` and `DEVELOPMENT_TEAM=` carry a value.
    """
    violations: list[str] = []
    if not argv or pathlib.Path(argv[0]).name != "xcodebuild":
        return [f"not an xcodebuild invocation: {argv[:1]}"]

    arguments = argv[1:]
    for token, why in FORBIDDEN_COMMAND_TOKENS:
        if token in arguments:
            violations.append(f"forbidden argument {token!r}: {why}")

    if "-destination" not in arguments:
        violations.append("no -destination: xcodebuild would choose one")
    else:
        for index, argument in enumerate(arguments):
            if argument != "-destination":
                continue
            value = arguments[index + 1] if index + 1 < len(arguments) else ""
            if not value.startswith("generic/"):
                violations.append(
                    f"-destination {value!r} is not generic: only "
                    f"{GENERIC_SIMULATOR_DESTINATION!r} compiles without a destination"
                )
            for selector in CONCRETE_DESTINATION_SELECTORS:
                if selector in value:
                    violations.append(
                        f"-destination {value!r} names a concrete destination via "
                        f"{selector!r}, which is a deployment target"
                    )

    if "CODE_SIGNING_ALLOWED=NO" not in arguments:
        violations.append("CODE_SIGNING_ALLOWED=NO absent: the build could sign a product")
    for setting in SIGNING_REENABLING_SETTINGS:
        for argument in arguments:
            if argument.startswith(setting):
                violations.append(f"{argument!r} re-enables or configures signing")

    if "-derivedDataPath" not in arguments:
        violations.append(
            "-derivedDataPath absent: both schemes build DefAIke.app to the same shared "
            "path, so the second build would overwrite the first archive"
        )

    for flag in OFFLINE_PACKAGE_FLAGS:
        if flag not in arguments:
            violations.append(
                f"{flag} absent: the build could resolve a package version the release did "
                "not approve, over the network"
            )
    return violations


@dataclasses.dataclass(frozen=True)
class XcodebuildInvocation:
    """The only producer of `xcodebuild` argument lists in this file.

    Constructing one cannot express a deployment: the action is restricted to the two
    compile-only actions, the destination is fixed, signing is off, and the derived-data
    path is required. `argv` is screened before it is returned so a future edit that widened
    the action set would fail here rather than in review.
    """

    action: str
    scheme: str
    configuration: str
    derived_data: pathlib.Path

    COMPILE_ONLY_ACTIONS = ("build", "build-for-testing")

    def __post_init__(self) -> None:
        if self.action not in self.COMPILE_ONLY_ACTIONS:
            raise ValueError(
                f"action {self.action!r} is not compile-only; permitted: "
                f"{self.COMPILE_ONLY_ACTIONS}"
            )

    @property
    def argv(self) -> list[str]:
        argv = [
            "xcodebuild",
            self.action,
            "-workspace",
            str(WORKSPACE),
            "-scheme",
            self.scheme,
            "-configuration",
            self.configuration,
            "-destination",
            GENERIC_SIMULATOR_DESTINATION,
            "-derivedDataPath",
            str(self.derived_data),
            *OFFLINE_PACKAGE_FLAGS,
            "CODE_SIGNING_ALLOWED=NO",
        ]
        violations = command_line_violations(argv)
        if violations:
            raise ValueError("constructed an unsafe xcodebuild invocation: " + "; ".join(violations))
        return argv


# MARK: - Evidence scope

# One entry per `ValidationVersionTuple` field, plus the observable identity fields a build
# does carry. `source` names where a resolved value came from; nothing is inferred.
@dataclasses.dataclass(frozen=True)
class ScopeField:
    name: str
    value: str | list[str] | dict[str, str] | None
    source: str
    # Why this field has no value. Empty for a resolved field.
    unresolved_reason: str = ""

    @property
    def is_resolved(self) -> bool:
        return not self.unresolved_reason

    def as_dict(self) -> dict:
        return {
            "field": self.name,
            "value": self.value,
            "source": self.source,
            "resolved": self.is_resolved,
            "unresolvedReason": self.unresolved_reason,
        }


@dataclasses.dataclass(frozen=True)
class EvidenceScope:
    """The observed counterpart of `ValidationVersionTuple`, for one composition.

    Not a claim that the tuple is coherent. It is the measurement of how much of the tuple
    this working tree can resolve, with each unresolved field naming what is missing. Two
    scopes are joinable only when every field matches, which is what `require_joinable`
    enforces and what `--self-test` proves refuses the 14.9 case.
    """

    composition: str
    fields: tuple[ScopeField, ...]

    @property
    def unresolved(self) -> list[str]:
        return [field.name for field in self.fields if not field.is_resolved]

    @property
    def is_provisional(self) -> bool:
        return bool(self.unresolved)

    def as_dict(self) -> dict:
        body = {
            "composition": self.composition,
            "fields": [field.as_dict() for field in self.fields],
            "unresolvedFields": sorted(self.unresolved),
            "provisional": self.is_provisional,
        }
        body["scopeDigest"] = hashlib.sha256(
            json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        return body

    @property
    def digest(self) -> str:
        return self.as_dict()["scopeDigest"]


def read_project_yml_setting(text: str, key: str) -> str | None:
    match = re.search(rf'^\s*{re.escape(key)}:\s*"?([^"\n]*)"?\s*$', text, re.MULTILINE)
    return match.group(1).strip() if match else None


def resolved_package_pins() -> dict[str, dict[str, str]]:
    """Version *and* revision for every pin, from `Package.resolved` only.

    Revision is included because a version alone cannot distinguish a re-tagged upstream,
    and 14.6 already treats a missing or changed revision as a finding rather than a pass.
    """
    document = json.loads(PACKAGE_RESOLVED.read_text(encoding="utf-8"))
    pins: dict[str, dict[str, str]] = {}
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        pins[pin["identity"]] = {
            "version": state.get("version", ""),
            "revision": state.get("revision", ""),
        }
    return pins


def reviewed_provenance_version() -> tuple[str, str]:
    """The provenance capability's implementation version, and where it was read.

    Read from `C2PALibraryReader.reviewedImplementationVersion` rather than written as a
    literal here, for the reason 12.3 gives: a build must not be able to claim a validator
    release it does not link. This script does not re-check that the four version-pin sites
    agree — 12.3 owns that check and is run as a gate.
    """
    source = PACKAGE_DIR / "Sources" / "DefAIkeProvenanceC2PA" / "C2PALibraryReader.swift"
    match = re.search(
        r'reviewedImplementationVersion\s*=\s*"([^"]+)"', source.read_text(encoding="utf-8")
    )
    if not match:
        return "", f"{source.relative_to(IOS)} (reviewedImplementationVersion not found)"
    return match.group(1), f"{source.relative_to(IOS)}:reviewedImplementationVersion"


def observe_scope(composition: Composition) -> EvidenceScope:
    """Resolve what the working tree can resolve; record everything else as unresolved."""
    project = PROJECT_YML.read_text(encoding="utf-8")
    pins = resolved_package_pins()
    provenance_version, provenance_source = reviewed_provenance_version()

    current_project_version = read_project_yml_setting(project, "CURRENT_PROJECT_VERSION")
    marketing_version = read_project_yml_setting(project, "MARKETING_VERSION")
    is_placeholder_build = (
        current_project_version == PLACEHOLDER_BUILD_IDENTITY["CURRENT_PROJECT_VERSION"]
        and marketing_version == PLACEHOLDER_BUILD_IDENTITY["MARKETING_VERSION"]
    )

    implementation_versions: dict[str, str] = {}
    for capability in composition.capabilities:
        if capability == "content-credential-validation":
            implementation_versions[capability] = provenance_version
        else:
            # No module in the tree declares an implementation version for these, and this
            # script will not invent one. Recorded as the empty string so the field below
            # is unresolved rather than plausible.
            implementation_versions[capability] = ""

    unresolved_implementations = sorted(
        capability for capability, version in implementation_versions.items() if not version
    )

    fields = [
        ScopeField(
            name="appBuild",
            value=None,
            source=f"{PROJECT_YML.name} MARKETING_VERSION/CURRENT_PROJECT_VERSION",
            unresolved_reason=(
                "both shipping targets record the placeholder build identity "
                f"{marketing_version}/{current_project_version}, so there is no AppBuildID "
                "and no artifact can be bound to a release version"
                if is_placeholder_build
                else "build identity is not the known placeholder but is still not a "
                "release-approved AppBuildID"
            ),
        ),
        ScopeField(
            name="bundleIdentifier",
            value=composition.bundle_identifier,
            source=f"{PROJECT_YML.name} PRODUCT_BUNDLE_IDENTIFIER for {composition.scheme}",
        ),
        ScopeField(
            name="capabilities",
            value=sorted(composition.capabilities),
            source=f"{PROJECT_YML.name} target graph for {composition.scheme}",
        ),
        ScopeField(
            name="capabilityImplementationVersions",
            value=dict(sorted(implementation_versions.items())),
            source=provenance_source if provenance_version else "no declaring module",
            unresolved_reason=(
                "no implementation version is declared for "
                + ", ".join(unresolved_implementations)
                if unresolved_implementations
                else ""
            ),
        ),
        ScopeField(
            name="resolvedPackagePins",
            value={
                identity: f"{pin['version']}@{pin['revision']}"
                for identity, pin in sorted(pins.items())
            },
            source=str(PACKAGE_RESOLVED.relative_to(IOS)),
        ),
        ScopeField(
            name="modelBundle",
            value=None,
            source="signed Model Bundle artifact",
            unresolved_reason="no signed Model Bundle exists in the working tree",
        ),
        ScopeField(
            name="fixtureSuite",
            value=None,
            source="Release Fixture Suite artifact",
            unresolved_reason="no release-approved fixture suite artifact exists",
        ),
        ScopeField(
            name="validationPlan",
            value=None,
            source="Device Validation Plan artifact",
            unresolved_reason="no signed Device Validation Plan exists",
        ),
        ScopeField(
            name="capabilityManifest",
            value=None,
            source="signed Release Capability Manifest artifact",
            unresolved_reason="no signed Release Capability Manifest exists",
        ),
        ScopeField(
            name="calibrationPolicy",
            value=None,
            source="Calibration Policy artifact",
            unresolved_reason="no validated Calibration Policy artifact exists",
        ),
        ScopeField(
            name="lifecyclePolicy",
            value=None,
            source="Data Lifecycle Policy artifact",
            unresolved_reason="no active Data Lifecycle Policy artifact exists",
        ),
    ]
    return EvidenceScope(composition=composition.name, fields=tuple(fields))


class JoinRefused(Exception):
    """Two artifacts from different evidence scopes were about to be combined."""


def require_joinable(current: dict, incoming: dict, what: str) -> None:
    """Refuse to join evidence from two different version tuples.

    Whole-scope comparison, field by field, including `capabilityImplementationVersions`.
    Requirement 13.20 excludes a configuration whose evidence mixes any tuple component, and
    "mixes" includes an implementation version: task 14.9 found `ParityRunBinding` binds two
    tuples that differ only there. This function is the pipeline's guard against the same
    class of join, and `--self-test` includes that exact case.
    """
    if not isinstance(incoming, dict) or "fields" not in incoming:
        raise JoinRefused(f"{what}: carries no evidence scope, so it cannot be joined")

    current_fields = {entry["field"]: entry for entry in current["fields"]}
    incoming_fields = {entry["field"]: entry for entry in incoming["fields"]}
    differences: list[str] = []
    for name in sorted(set(current_fields) | set(incoming_fields)):
        mine = current_fields.get(name)
        theirs = incoming_fields.get(name)
        if mine is None:
            differences.append(f"{name}: absent from this run, present in {what}")
        elif theirs is None:
            differences.append(f"{name}: present in this run, absent from {what}")
        elif mine["value"] != theirs["value"] or mine["resolved"] != theirs["resolved"]:
            differences.append(
                f"{name}: this run has {mine['value']!r}, {what} has {theirs['value']!r}"
            )
    if differences:
        raise JoinRefused(f"{what}: evidence scope differs — " + "; ".join(differences))
    if current.get("composition") != incoming.get("composition"):
        raise JoinRefused(
            f"{what}: composition differs — this run is "
            f"{current.get('composition')!r}, {what} is {incoming.get('composition')!r}"
        )


# MARK: - Gates and outcomes

# `GateOutcome` in `DefAIkeDomain` has exactly these three values and `isPassing` is true
# only for `passed`. There is no warning level, deliberately.
PASSED = "passed"
FAILED = "failed"
NOT_EXECUTED = "not-executed"


@dataclasses.dataclass
class GateResult:
    """One pipeline gate's outcome, plus what it owes and where its log is."""

    gate: str
    outcome: str
    detail: str = ""
    owed_inputs: list[str] = dataclasses.field(default_factory=list)
    log: str = ""
    duration_seconds: float = 0.0
    # A `ReleaseGate` raw value when this gate maps onto one, otherwise empty. Gates that
    # measure the development build rather than a release artifact map to nothing, and
    # claiming otherwise would put a simulator result into a release record.
    release_gate: str = ""

    def as_dict(self) -> dict:
        return {
            "gate": self.gate,
            "outcome": self.outcome,
            "detail": self.detail,
            "owedInputs": sorted(self.owed_inputs),
            "log": self.log,
            "durationSeconds": round(self.duration_seconds, 1),
            "releaseGate": self.release_gate,
        }

    @property
    def is_passing(self) -> bool:
        return self.outcome == PASSED and not self.owed_inputs


STAGES = (
    "toolchain",
    "identity",
    "module-boundaries",
    "host-suite",
    "build-debug",
    "build-release",
    "build-for-testing",
    "device-suites",
    "archive-audits",
    "release-artifacts",
)


# MARK: - The run

class Pipeline:
    def __init__(
        self,
        run_directory: pathlib.Path,
        stages: tuple[str, ...],
        release_artifacts: pathlib.Path | None,
        quiet: bool = False,
    ) -> None:
        self.run_directory = run_directory
        self.stages = stages
        self.release_artifacts = release_artifacts
        self.quiet = quiet
        self.results: list[GateResult] = []
        self.scopes: dict[str, EvidenceScope] = {}
        self.logs = run_directory / "logs"
        self.artifacts = run_directory / "artifacts"
        self.commands: list[dict] = []

    # -- plumbing

    def say(self, message: str) -> None:
        if not self.quiet:
            print(message, flush=True)

    def record(self, result: GateResult) -> GateResult:
        self.results.append(result)
        mark = {PASSED: "ok  ", FAILED: "FAIL", NOT_EXECUTED: "----"}[result.outcome]
        owed = f"  [owes {len(result.owed_inputs)}]" if result.owed_inputs else ""
        self.say(f"  {mark} {result.gate}{owed}  {result.detail}")
        return result

    def environment(self) -> dict[str, str]:
        """A fixed, noninteractive environment for every child process.

        `DEVELOPER_DIR` because `xcode-select -p` points at the Command Line Tools install
        here. The rest suppresses anything that would wait for a human or vary between runs.
        """
        environment = dict(os.environ)
        environment["DEVELOPER_DIR"] = str(XCODE_DEVELOPER_DIR)
        environment["NSUnbufferedIO"] = "YES"
        environment["CI"] = "1"
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment

    def run_logged(self, argv: list[str], log_name: str, cwd: pathlib.Path) -> tuple[int, str]:
        """Run one child process with stdin closed and all output on disk.

        stdin is `/dev/null` so nothing can prompt. `xcodebuild` output is tens of megabytes
        of compiler command lines, so it is never held in memory or echoed: the log path
        goes into the run manifest and only a derived summary is printed.
        """
        self.logs.mkdir(parents=True, exist_ok=True)
        log_path = self.logs / log_name
        with open(os.devnull, "rb") as devnull, log_path.open("wb") as log:
            completed = subprocess.run(
                argv,
                cwd=str(cwd),
                stdin=devnull,
                stdout=log,
                stderr=subprocess.STDOUT,
                env=self.environment(),
                check=False,
            )
        self.commands.append(
            {"argv": argv, "log": log_path.name, "exitStatus": completed.returncode}
        )
        return completed.returncode, log_path.name

    def build_root(self, configuration: str, composition: Composition) -> pathlib.Path:
        """A per-scheme, per-configuration derived-data root.

        The whole point: both schemes build `DefAIke.app` under a shared `PRODUCT_NAME`, so
        a shared root leaves one inspectable archive and the audits need two.
        """
        return self.run_directory / "derived" / configuration.lower() / composition.name

    def products(self, configuration: str, composition: Composition) -> pathlib.Path:
        return (
            self.build_root(configuration, composition)
            / "Build"
            / "Products"
            / f"{configuration}-iphonesimulator"
        )

    # -- stages

    def stage_toolchain(self) -> None:
        self.say("Toolchain")
        if not XCODE_DEVELOPER_DIR.is_dir():
            self.record(
                GateResult(
                    gate="toolchain-xcode-present",
                    outcome=FAILED,
                    detail=f"{XCODE_DEVELOPER_DIR} does not exist; the iOS SDK is required",
                )
            )
            return
        status, log = self.run_logged(
            ["xcodebuild", "-version", "-sdk", "iphonesimulator", "SDKVersion"],
            "toolchain-sdk.log",
            IOS,
        )
        text = (self.logs / log).read_text(encoding="utf-8", errors="replace").strip()
        self.record(
            GateResult(
                gate="toolchain-xcode-present",
                outcome=PASSED if status == 0 else FAILED,
                detail=text.replace("\n", " ")[:120] if status == 0 else f"exit {status}",
                log=log,
            )
        )

    def stage_identity(self) -> None:
        self.say("Evidence scope")
        for composition in COMPOSITIONS:
            scope = observe_scope(composition)
            self.scopes[composition.name] = scope
            self.record(
                GateResult(
                    gate=f"evidence-scope-complete[{composition.name}]",
                    # A provisional scope is not a pass. Requirement 13.18 admits a
                    # configuration only on a complete matching tuple, so an incomplete
                    # observed tuple must block, and 13.17's record cannot be produced.
                    outcome=FAILED if scope.is_provisional else PASSED,
                    detail=(
                        f"digest {scope.digest[:16]} provisional; "
                        f"{len(scope.unresolved)} unresolved tuple field(s)"
                        if scope.is_provisional
                        else f"digest {scope.digest[:16]} complete"
                    ),
                    owed_inputs=sorted(scope.unresolved),
                    release_gate="capability-manifest-match",
                )
            )

    def stage_module_boundaries(self) -> None:
        self.say("Declared module closure")
        status, log = self.run_logged(
            [
                sys.executable,
                str(SCRIPTS / "check-module-boundaries.py"),
                "--require-xcode-project",
            ],
            "check-module-boundaries.log",
            IOS,
        )
        self.record(
            GateResult(
                gate="module-boundaries",
                outcome=PASSED if status == 0 else FAILED,
                detail=f"check-module-boundaries.py --require-xcode-project exit {status}",
                log=log,
            )
        )

    def stage_host_suite(self) -> None:
        """The module suites, on the host, through the script that already owns them.

        `host-test.sh` builds all four composition products and runs the whole package test
        suite. Its property tests are slow by design — 51 of them, tens of seconds each — so
        nothing here imposes a timeout and nothing skips them. No timeout at all is passed to
        any child process in this pipeline: a truncated suite would be a fabricated result.

        Host results are development evidence. This gate maps to no `ReleaseGate`.
        """
        self.say("Package module suites (host)")
        started = time.monotonic()
        status, log = self.run_logged(
            [str(SCRIPTS / "host-test.sh")], "host-test.log", IOS
        )
        text = (self.logs / log).read_text(encoding="utf-8", errors="replace")
        summary = ""
        match = re.search(r"Test run with (\d+) tests? in (\d+) suites?[^\n]*", text)
        if match:
            summary = match.group(0)[:140]
        self.record(
            GateResult(
                gate="host-module-suites",
                outcome=PASSED if status == 0 else FAILED,
                detail=summary or f"host-test.sh exit {status}",
                log=log,
                duration_seconds=time.monotonic() - started,
            )
        )

    def _build(self, action: str, configuration: str, gate_prefix: str) -> None:
        for composition in COMPOSITIONS:
            invocation = XcodebuildInvocation(
                action=action,
                scheme=composition.scheme,
                configuration=configuration,
                derived_data=self.build_root(configuration, composition),
            )
            started = time.monotonic()
            status, log = self.run_logged(
                invocation.argv,
                f"{gate_prefix}-{composition.name}.log",
                IOS,
            )
            text = (self.logs / log).read_text(encoding="utf-8", errors="replace")
            errors = len(re.findall(r"^.*error:", text, re.MULTILINE))
            self.record(
                GateResult(
                    gate=f"{gate_prefix}[{composition.name}]",
                    outcome=PASSED if status == 0 and errors == 0 else FAILED,
                    detail=(
                        f"{action} {configuration}: exit {status}, {errors} error line(s)"
                    ),
                    log=log,
                    duration_seconds=time.monotonic() - started,
                )
            )

    def stage_build_debug(self) -> None:
        # Debug is not a preference: `check-offline-privacy-archive.py` and
        # `audit-release-archives.py` both read `Build/Products/Debug-iphonesimulator` and
        # `Intermediates.noindex/**/Objects-normal/<arch>/`, so the archive audits require a
        # Debug root. 14.6 already records that a Debug simulator build is not a
        # distribution artifact.
        self.say("Compile both compositions (Debug)")
        self._build("build", "Debug", "build-debug")

    def stage_build_release(self) -> None:
        # Release is where `SWIFT_TREAT_WARNINGS_AS_ERRORS` and
        # `GCC_TREAT_WARNINGS_AS_ERRORS` are on (`project.yml:68-70`), so a warning that
        # Debug tolerates fails here. Compiling both configurations is the only way that
        # difference is ever observed.
        self.say("Compile both compositions (Release, warnings are errors)")
        self._build("build", "Release", "build-release")

    def stage_build_for_testing(self) -> None:
        """Compile the UI and device-validation XCTest bundles without running them.

        `build-for-testing` with a generic destination compiles a test target and produces
        its `.xctestrun`, and boots nothing. It is the most that can be established about
        those bundles without a deployment.
        """
        self.say("Compile the on-device test bundles (no destination, no boot)")
        self._build("build-for-testing", "Debug", "build-for-testing")

    def stage_device_suites(self) -> None:
        """Record device and UI suite execution as not-executed, and refuse to soften it.

        There is no physical device. `ObservedParityEnvironment.current` is compiled from
        `#if targetEnvironment(simulator)` with no setter, and
        `GateResultReference(outcome: .passed, environment: .developmentMac)` throws while
        `.failed` constructs — the type system already refuses to let a Mac or simulator
        result pass a device gate. Running these bundles on a simulator would need a
        concrete destination, a boot, an install, and a launch, all forbidden, and the
        result would be inadmissible anyway.

        So the outcome is `not-executed`, it is hard-coded to `not-executed`, and
        `not-executed` does not satisfy a gate. This is the correct reported state, not a
        limitation to work around.
        """
        self.say("Physical-device and UI suites")
        for composition in COMPOSITIONS:
            for suite in ("DefAIkeDeviceValidationTests", "DefAIkeUITests"):
                self.record(
                    GateResult(
                        gate=f"{suite}-execution[{composition.name}]",
                        outcome=NOT_EXECUTED,
                        detail=(
                            "no physical device is available; a simulator result cannot "
                            "satisfy a physical-device gate and running it would require a "
                            "concrete destination, a boot, an install, and a launch"
                        ),
                        owed_inputs=["physical-device-execution-evidence"],
                        release_gate="device-allowlist",
                    )
                )

    def stage_archive_audits(self) -> None:
        """Run the four archive-consuming checks over the two Debug roots.

        Each is run through its own owner rather than re-derived. `--json` outputs are
        collected into this run's artifact directory, and every one of them is rewritten
        with this run's evidence scope attached, so a report cannot later be joined to a
        different tuple.
        """
        self.say("Archive audits")
        debug_products = {
            composition.name: self.products("Debug", composition)
            for composition in COMPOSITIONS
        }
        debug_roots = {
            composition.name: self.build_root("Debug", composition)
            for composition in COMPOSITIONS
        }
        missing = [name for name, path in debug_products.items() if not (path / "DefAIke.app").is_dir()]
        if missing:
            self.record(
                GateResult(
                    gate="archive-audits",
                    outcome=FAILED,
                    detail=(
                        "no Debug archive for " + ", ".join(sorted(missing))
                        + "; run the build-debug stage first"
                    ),
                    release_gate="archive-audit",
                )
            )
            return

        self.artifacts.mkdir(parents=True, exist_ok=True)

        for composition in COMPOSITIONS:
            status, log = self.run_logged(
                [
                    sys.executable,
                    str(SCRIPTS / "check-share-extension-target.py"),
                    "--products",
                    str(debug_products[composition.name]),
                ],
                f"check-share-extension-target-{composition.name}.log",
                IOS,
            )
            self.record(
                GateResult(
                    gate=f"share-extension-target[{composition.name}]",
                    outcome=PASSED if status == 0 else FAILED,
                    detail=f"exit {status}",
                    log=log,
                    release_gate="archive-audit",
                )
            )

        for composition in COMPOSITIONS:
            report = self.artifacts / f"capability-composition-{composition.name}.json"
            status, log = self.run_logged(
                [
                    sys.executable,
                    str(SCRIPTS / "check-capability-composition.py"),
                    "--products",
                    str(debug_products[composition.name]),
                    "--expect",
                    composition.expect,
                    "--json",
                    str(report),
                ],
                f"check-capability-composition-{composition.name}.log",
                IOS,
            )
            self.bind_artifact(report, composition.name)
            self.record(
                GateResult(
                    gate=f"capability-composition[{composition.name}]",
                    outcome=PASSED if status == 0 else FAILED,
                    detail=f"exit {status}",
                    log=log,
                    release_gate="capability-manifest-match",
                )
            )

        offline_report = self.artifacts / "offline-privacy-archive.json"
        status, log = self.run_logged(
            [
                sys.executable,
                str(SCRIPTS / "check-offline-privacy-archive.py"),
                "--pixel-only-build",
                str(debug_roots["pixel-only"]),
                "--provenance-build",
                str(debug_roots["pixel-plus-provenance"]),
                "--json",
                str(offline_report),
            ],
            "check-offline-privacy-archive.log",
            IOS,
        )
        # This report covers both compositions, so it is bound to both scopes rather than
        # to one of them, and a consumer that has only one scope cannot join it.
        self.bind_artifact(offline_report, *[composition.name for composition in COMPOSITIONS])
        self.record(
            GateResult(
                gate="offline-privacy-archive",
                outcome=PASSED if status == 0 else FAILED,
                detail=f"exit {status}",
                log=log,
                release_gate="privacy-audit",
            )
        )

        sbom_directory = self.artifacts / "sbom"
        audit_report = self.artifacts / "release-archive-audit.json"
        release_input = self.artifacts / "release-record-input.json"
        status, log = self.run_logged(
            [
                sys.executable,
                str(SCRIPTS / "audit-release-archives.py"),
                "--pixel-only-build",
                str(debug_roots["pixel-only"]),
                "--provenance-build",
                str(debug_roots["pixel-plus-provenance"]),
                "--sbom-directory",
                str(sbom_directory),
                "--json",
                str(audit_report),
                "--release-input",
                str(release_input),
            ],
            "audit-release-archives.log",
            IOS,
        )
        both = [composition.name for composition in COMPOSITIONS]
        self.bind_artifact(audit_report, *both)
        self.bind_artifact(release_input, *both)
        # The SBOMs are CycloneDX 1.6 documents and a consumer expects that schema at the
        # top level, so wrapping them would break them. They get a sidecar instead, which
        # names the exact bytes by digest — a stronger binding than a wrapper, because it
        # also detects a substituted SBOM rather than only a mislabelled one.
        self.bind_sidecar(sbom_directory, *both)
        owed = self.owed_from_release_input(release_input)
        self.record(
            GateResult(
                gate="release-archive-audit",
                outcome=PASSED if status == 0 else FAILED,
                detail=(
                    f"exit {status}; SBOM in artifacts/sbom, typed release input in "
                    "artifacts/release-record-input.json"
                ),
                owed_inputs=owed,
                log=log,
                release_gate="archive-audit",
            )
        )

    def owed_from_release_input(self, path: pathlib.Path) -> list[str]:
        """14.6's owed inputs, read from its own typed output rather than from its prose."""
        if not path.is_file():
            return []
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return []
        return sorted(document.get("payload", document).get("unprovisionedInputs", []))

    def bind_artifact(self, path: pathlib.Path, *composition_names: str) -> None:
        """Wrap one produced artifact so it names the exact scope it was produced under.

        Rewritten in place as `{evidenceScope, provisional, producedBy, payload}`. A reader
        that wants the payload has to walk past the scope to reach it, so an artifact cannot
        be consumed without seeing which tuple it belongs to. `provisional` is true whenever
        any bound scope is provisional — which is every run today, because the app build is
        a placeholder.
        """
        if not path.is_file():
            return
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return
        if isinstance(payload, dict) and "evidenceScope" in payload:
            return
        scopes = [self.scopes[name].as_dict() for name in composition_names if name in self.scopes]
        wrapped = {
            "evidenceScope": scopes,
            "provisional": any(scope["provisional"] for scope in scopes) or not scopes,
            "producedBy": "ios/Scripts/release-pipeline.py",
            "task": "15.1",
            "payload": payload,
        }
        path.write_text(json.dumps(wrapped, indent=2, sort_keys=True), encoding="utf-8")

    def bind_sidecar(self, directory: pathlib.Path, *composition_names: str) -> None:
        """Bind a directory of schema-fixed artifacts without rewriting any of them.

        Writes `evidence-scope.json` naming every sibling file, its size, and its SHA-256.
        Used where wrapping would break a document another tool has to read — the CycloneDX
        SBOMs. Digesting the bytes means a swapped file from another run is detectable, not
        only a wrongly labelled one.
        """
        if not directory.is_dir():
            return
        scopes = [self.scopes[name].as_dict() for name in composition_names if name in self.scopes]
        entries = []
        for path in sorted(directory.iterdir()):
            if not path.is_file() or path.name == "evidence-scope.json":
                continue
            data = path.read_bytes()
            entries.append(
                {
                    "file": path.name,
                    "byteCount": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
        (directory / "evidence-scope.json").write_text(
            json.dumps(
                {
                    "evidenceScope": scopes,
                    "provisional": any(scope["provisional"] for scope in scopes) or not scopes,
                    "producedBy": "ios/Scripts/release-pipeline.py",
                    "task": "15.1",
                    "boundFiles": entries,
                },
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )

    def stage_release_artifacts(self) -> None:
        """Validate release artifacts the operator supplied. Never supply one.

        Requirement 14.1 wants each gate mapped to a source artifact identifier and version,
        and 14.15 blocks on any missing or failing mandatory entry. So this stage validates
        what `--release-artifacts DIR` contains and reports the rest as owed. It does not
        create, complete, default, sign, or approve an artifact, and it does not decide that
        a missing one is acceptable.

        Validation is exactly three things, all of which are checks rather than choices:
        the file parses as JSON; it carries an `evidenceScope`; and that scope is joinable
        with this run's under `require_joinable`, whole-tuple. A supplied artifact from a
        different app build, capability set, or implementation version is refused.
        """
        self.say("Supplied release artifacts")
        required = sorted(
            {
                owed
                for result in self.results
                for owed in result.owed_inputs
            }
        )
        if self.release_artifacts is None:
            self.record(
                GateResult(
                    gate="supplied-release-artifacts",
                    outcome=FAILED,
                    detail=(
                        "no --release-artifacts directory supplied; every release-controlled "
                        "input remains owed and no gate that needs one can pass"
                    ),
                    owed_inputs=required,
                    release_gate="",
                )
            )
            return

        if not self.release_artifacts.is_dir():
            self.record(
                GateResult(
                    gate="supplied-release-artifacts",
                    outcome=FAILED,
                    detail=f"{self.release_artifacts} is not a directory",
                    owed_inputs=required,
                )
            )
            return

        supplied = sorted(self.release_artifacts.glob("*.json"))
        if not supplied:
            self.record(
                GateResult(
                    gate="supplied-release-artifacts",
                    outcome=FAILED,
                    detail=f"{self.release_artifacts} contains no .json artifact",
                    owed_inputs=required,
                )
            )
            return

        refusals: list[str] = []
        accepted = 0
        for artifact in supplied:
            try:
                document = json.loads(artifact.read_text(encoding="utf-8"))
            except json.JSONDecodeError as error:
                refusals.append(f"{artifact.name}: not JSON ({error.msg})")
                continue
            scope = document.get("evidenceScope") if isinstance(document, dict) else None
            if scope is None:
                refusals.append(
                    f"{artifact.name}: carries no evidenceScope, so it cannot be bound to "
                    "a version tuple"
                )
                continue
            entries = scope if isinstance(scope, list) else [scope]
            for entry in entries:
                composition = entry.get("composition") if isinstance(entry, dict) else None
                mine = self.scopes.get(composition or "")
                if mine is None:
                    refusals.append(
                        f"{artifact.name}: names composition {composition!r}, which this run "
                        "did not observe"
                    )
                    continue
                try:
                    require_joinable(mine.as_dict(), entry, artifact.name)
                except JoinRefused as error:
                    refusals.append(str(error))
                else:
                    accepted += 1

        self.record(
            GateResult(
                gate="supplied-release-artifacts",
                outcome=FAILED if refusals or not accepted else PASSED,
                detail=(
                    f"{accepted} joinable scope binding(s), {len(refusals)} refusal(s)"
                    + ("; " + refusals[0] if refusals else "")
                ),
                owed_inputs=required,
            )
        )

    # -- driving

    def run(self) -> int:
        self.run_directory.mkdir(parents=True, exist_ok=True)
        dispatch = {
            "toolchain": self.stage_toolchain,
            "identity": self.stage_identity,
            "module-boundaries": self.stage_module_boundaries,
            "host-suite": self.stage_host_suite,
            "build-debug": self.stage_build_debug,
            "build-release": self.stage_build_release,
            "build-for-testing": self.stage_build_for_testing,
            "device-suites": self.stage_device_suites,
            "archive-audits": self.stage_archive_audits,
            "release-artifacts": self.stage_release_artifacts,
        }
        # The evidence scope is what every artifact is bound to, so it is observed whenever
        # any stage that emits an artifact runs, even if `identity` was not requested.
        emits_artifacts = {"archive-audits", "release-artifacts"}
        if not self.scopes and (set(self.stages) & emits_artifacts):
            for composition in COMPOSITIONS:
                self.scopes[composition.name] = observe_scope(composition)

        for stage in STAGES:
            if stage in self.stages:
                dispatch[stage]()
        return self.finish()

    def finish(self) -> int:
        manifest = {
            "producedBy": "ios/Scripts/release-pipeline.py",
            "task": "15.1",
            "schemaVersion": 1,
            "stagesRequested": list(self.stages),
            "evidenceScope": [scope.as_dict() for scope in self.scopes.values()],
            "provisional": any(scope.is_provisional for scope in self.scopes.values()),
            "gates": [result.as_dict() for result in self.results],
            "commands": self.commands,
        }
        self.run_directory.mkdir(parents=True, exist_ok=True)
        (self.run_directory / "pipeline-run.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
        )

        failed = [result for result in self.results if result.outcome == FAILED]
        not_executed = [result for result in self.results if result.outcome == NOT_EXECUTED]
        owed = sorted({owed for result in self.results for owed in result.owed_inputs})

        # Two refusals that do not depend on any individual gate, because both are ways an
        # exit 0 could be obtained without having verified anything.
        #
        # `--stages` exists to iterate on one stage, and a narrowed run must not be able to
        # report success: with only `release-artifacts` selected there are no prior gates, so
        # nothing is owed and the gate could pass on its own. Success is reserved for the
        # complete stage set.
        #
        # And a provisional evidence scope can never pass, whatever the gates say. Every
        # artifact this run produced is bound to a tuple with an unresolved app build, so
        # there is no coherent version tuple for a passing result to belong to.
        incomplete_stages = sorted(set(STAGES) - set(self.stages))
        provisional = [name for name, scope in self.scopes.items() if scope.is_provisional]

        self.say("")
        self.say(f"run directory   {self.run_directory}")
        self.say(f"manifest        {self.run_directory / 'pipeline-run.json'}")
        for name, scope in self.scopes.items():
            self.say(
                f"scope {name:<22} {scope.digest[:16]} "
                f"{'provisional' if scope.is_provisional else 'complete'}"
            )
        self.say(
            f"gates           {len(self.results)} total, {len(failed)} failed, "
            f"{len(not_executed)} not executed"
        )
        if owed:
            self.say(f"owed inputs     {len(owed)}")
            for identifier in owed:
                self.say(f"                  {identifier}")

        if incomplete_stages:
            self.say(f"stages skipped  {len(incomplete_stages)}: {', '.join(incomplete_stages)}")
        if provisional:
            self.say(f"provisional     {', '.join(sorted(provisional))}")

        if failed or not_executed or owed or incomplete_stages or provisional:
            self.say("")
            reasons = []
            if failed:
                reasons.append(f"{len(failed)} failing gate(s)")
            if not_executed:
                reasons.append(f"{len(not_executed)} unexecuted gate(s)")
            if owed:
                reasons.append(f"{len(owed)} owed release-controlled input(s)")
            if incomplete_stages:
                reasons.append(f"{len(incomplete_stages)} skipped stage(s)")
            if provisional:
                reasons.append(f"{len(provisional)} provisional evidence scope(s)")
            self.say("PIPELINE FAILED: " + ", ".join(reasons) + ".")
            self.say(
                "Missing is not pass. An owed release-controlled input, an unexecuted gate, a "
                "skipped stage, and a provisional version tuple each block, and this pipeline "
                "supplies none of them."
            )
            return 1
        self.say("")
        self.say("pipeline passed")
        return 0


# MARK: - Non-vacuity validation

def self_test() -> int:
    """Prove each guarantee this script makes can fail, by making it fail.

    Every probe plants a violation and requires the check to report it, and where the check
    is a comparison it also requires the clean case to pass. A check that has never been
    shown to report a violation is worthless, so the count printed here is the evidence.
    """
    checks: list[tuple[str, bool, str]] = []

    def check(name: str, condition: bool, note: str = "") -> None:
        checks.append((name, condition, note))

    base = observe_scope(COMPOSITIONS[1])
    base_dict = base.as_dict()

    # 1. The observed tuple is provisional today, and the reason is the placeholder build.
    check(
        "observed scope is provisional",
        base.is_provisional,
        f"unresolved: {sorted(base.unresolved)}",
    )
    check("appBuild is unresolved", "appBuild" in base.unresolved)
    appbuild = next(field for field in base.fields if field.name == "appBuild")
    check(
        "appBuild reason names the placeholder identity",
        "0.0.0/0" in appbuild.unresolved_reason,
        appbuild.unresolved_reason,
    )

    # 2. A scope digest covers unresolved fields too, so it changes when one does.
    mutated = EvidenceScope(
        composition=base.composition,
        fields=tuple(
            dataclasses.replace(field, unresolved_reason="") if field.name == "appBuild" else field
            for field in base.fields
        ),
    )
    check("digest changes when a field's resolution changes", mutated.digest != base.digest)

    # 3. Joining: identical scopes join, and every single-field difference refuses.
    def refuses(incoming: dict) -> bool:
        try:
            require_joinable(base_dict, incoming, "probe")
        except JoinRefused:
            return True
        return False

    check("identical scope joins", not refuses(json.loads(json.dumps(base_dict))))

    # The 14.9 case, exactly: two tuples differing only in a capability implementation
    # version. `ParityRunBinding` binds these; this pipeline must not.
    only_implementation_version = json.loads(json.dumps(base_dict))
    for entry in only_implementation_version["fields"]:
        if entry["field"] == "capabilityImplementationVersions":
            entry["value"] = dict(entry["value"])
            entry["value"]["content-credential-validation"] = "0.0.13"
    check(
        "refuses a scope differing only in a capability implementation version",
        refuses(only_implementation_version),
        "the task-14.9 ParityRunBinding case",
    )

    only_app_build = json.loads(json.dumps(base_dict))
    for entry in only_app_build["fields"]:
        if entry["field"] == "appBuild":
            entry["value"] = "1.0.0/1"
            entry["resolved"] = True
    check("refuses a scope differing only in appBuild", refuses(only_app_build))

    only_capabilities = json.loads(json.dumps(base_dict))
    for entry in only_capabilities["fields"]:
        if entry["field"] == "capabilities":
            entry["value"] = ["pixel-analysis"]
    check("refuses a scope differing only in the capability set", refuses(only_capabilities))

    only_pins = json.loads(json.dumps(base_dict))
    for entry in only_pins["fields"]:
        if entry["field"] == "resolvedPackagePins":
            entry["value"] = dict(entry["value"])
            entry["value"]["c2pa-swift"] = "0.0.12@deadbeef"
    check("refuses a scope differing only in a resolved package revision", refuses(only_pins))

    dropped_field = json.loads(json.dumps(base_dict))
    dropped_field["fields"] = dropped_field["fields"][1:]
    check("refuses a scope missing a field", refuses(dropped_field))

    check("refuses a payload with no scope at all", refuses({"payload": {}}))

    other_composition = observe_scope(COMPOSITIONS[0]).as_dict()
    check("refuses the other composition's scope", refuses(other_composition))

    # 4. Outcome arithmetic: owed and not-executed never pass.
    check(
        "a passed gate that owes an input is not passing",
        not GateResult(gate="p", outcome=PASSED, owed_inputs=["x"]).is_passing,
    )
    check("a not-executed gate is not passing", not GateResult(gate="p", outcome=NOT_EXECUTED).is_passing)
    check("a failed gate is not passing", not GateResult(gate="p", outcome=FAILED).is_passing)
    check("a clean passed gate is passing", GateResult(gate="p", outcome=PASSED).is_passing)

    # 5. Exit status: any failure, any unexecuted gate, or any owed input yields 1.
    def exit_status_for(
        results: list[GateResult],
        stages: tuple[str, ...] = STAGES,
        scopes: dict[str, EvidenceScope] | None = None,
    ) -> int:
        pipeline = Pipeline(
            run_directory=pathlib.Path(tempfile.mkdtemp(prefix="t151-selftest-")),
            stages=stages,
            release_artifacts=None,
            quiet=True,
        )
        pipeline.results = results
        pipeline.scopes = scopes or {}
        try:
            return pipeline.finish()
        finally:
            shutil.rmtree(pipeline.run_directory, ignore_errors=True)

    check("all-clean yields exit 0", exit_status_for([GateResult(gate="a", outcome=PASSED)]) == 0)
    check(
        "one failure yields exit 1",
        exit_status_for(
            [GateResult(gate="a", outcome=PASSED), GateResult(gate="b", outcome=FAILED)]
        )
        == 1,
    )
    check(
        "one not-executed gate yields exit 1",
        exit_status_for(
            [GateResult(gate="a", outcome=PASSED), GateResult(gate="b", outcome=NOT_EXECUTED)]
        )
        == 1,
    )
    check(
        "one owed input yields exit 1",
        exit_status_for([GateResult(gate="a", outcome=PASSED, owed_inputs=["owed"])]) == 1,
    )
    # A narrowed stage selection must not be able to buy an exit 0.
    for skipped in STAGES:
        remaining = tuple(stage for stage in STAGES if stage != skipped)
        if exit_status_for([GateResult(gate="a", outcome=PASSED)], stages=remaining) != 1:
            check(f"skipping stage {skipped} yields exit 1", False, "it yielded 0")
            break
    else:
        check("skipping any single stage yields exit 1", True, f"{len(STAGES)} stages probed")
    # A provisional scope must not be able to buy an exit 0 either, even with clean gates.
    check(
        "a provisional evidence scope yields exit 1 even with every gate clean",
        exit_status_for(
            [GateResult(gate="a", outcome=PASSED)], scopes={base.composition: base}
        )
        == 1,
    )
    complete = EvidenceScope(
        composition=base.composition,
        fields=tuple(dataclasses.replace(field, unresolved_reason="") for field in base.fields),
    )
    check(
        "a complete evidence scope with clean gates yields exit 0",
        exit_status_for(
            [GateResult(gate="a", outcome=PASSED)], scopes={complete.composition: complete}
        )
        == 0,
        "so the two refusals above are refusals, not an unconditional failure",
    )

    # 6. The device suites cannot be reported as executed.
    pipeline = Pipeline(
        run_directory=pathlib.Path(tempfile.mkdtemp(prefix="t151-selftest-")),
        stages=("device-suites",),
        release_artifacts=None,
        quiet=True,
    )
    try:
        pipeline.stage_device_suites()
        check(
            "every device/UI suite gate is not-executed",
            bool(pipeline.results)
            and all(result.outcome == NOT_EXECUTED for result in pipeline.results),
            f"{len(pipeline.results)} gate(s)",
        )
        check(
            "every device/UI suite gate owes device evidence",
            all(
                "physical-device-execution-evidence" in result.owed_inputs
                for result in pipeline.results
            ),
        )
    finally:
        shutil.rmtree(pipeline.run_directory, ignore_errors=True)

    # 7. Supplied-artifact validation refuses, and refuses for the right reasons.
    def supplied_result(files: dict[str, str] | None) -> GateResult:
        directory = pathlib.Path(tempfile.mkdtemp(prefix="t151-supplied-"))
        run = pathlib.Path(tempfile.mkdtemp(prefix="t151-run-"))
        try:
            if files is None:
                artifacts = None
            else:
                artifacts = directory
                for name, body in files.items():
                    (directory / name).write_text(body, encoding="utf-8")
            probe = Pipeline(
                run_directory=run,
                stages=("release-artifacts",),
                release_artifacts=artifacts,
                quiet=True,
            )
            for composition in COMPOSITIONS:
                probe.scopes[composition.name] = observe_scope(composition)
            probe.stage_release_artifacts()
            return probe.results[-1]
        finally:
            shutil.rmtree(directory, ignore_errors=True)
            shutil.rmtree(run, ignore_errors=True)

    check("no supplied directory fails", supplied_result(None).outcome == FAILED)
    check("an empty supplied directory fails", supplied_result({}).outcome == FAILED)
    check(
        "unparseable supplied JSON fails",
        supplied_result({"a.json": "{not json"}).outcome == FAILED,
    )
    check(
        "a supplied artifact with no evidenceScope fails",
        supplied_result({"a.json": json.dumps({"payload": {}})}).outcome == FAILED,
    )
    matching = json.dumps({"evidenceScope": [base_dict], "payload": {}})
    check(
        "a supplied artifact whose scope matches this run is accepted",
        supplied_result({"a.json": matching}).outcome == PASSED,
    )
    check(
        "a supplied artifact whose scope differs only in an implementation version fails",
        supplied_result(
            {"a.json": json.dumps({"evidenceScope": [only_implementation_version], "payload": {}})}
        ).outcome
        == FAILED,
    )

    # 8. Binding: a produced artifact is rewritten with its scope, and stays provisional.
    directory = pathlib.Path(tempfile.mkdtemp(prefix="t151-bind-"))
    try:
        binder = Pipeline(run_directory=directory, stages=(), release_artifacts=None, quiet=True)
        binder.scopes[COMPOSITIONS[1].name] = base
        target = directory / "report.json"
        target.write_text(json.dumps({"findings": []}), encoding="utf-8")
        binder.bind_artifact(target, COMPOSITIONS[1].name)
        bound = json.loads(target.read_text(encoding="utf-8"))
        check("a bound artifact carries its evidence scope", "evidenceScope" in bound)
        check("a bound artifact keeps its payload", bound.get("payload") == {"findings": []})
        check("a bound artifact is marked provisional today", bound.get("provisional") is True)
        check(
            "a bound artifact's scope is joinable with the run that produced it",
            not refuses(bound["evidenceScope"][0]),
        )
        binder.bind_artifact(target, COMPOSITIONS[1].name)
        rebound = json.loads(target.read_text(encoding="utf-8"))
        check("binding is idempotent", rebound == bound)

        # 9. Sidecar binding leaves the bound document untouched and digests its bytes.
        sidecar_directory = directory / "sbom"
        sidecar_directory.mkdir()
        sbom = sidecar_directory / "sbom-probe.cdx.json"
        sbom_body = json.dumps({"bomFormat": "CycloneDX", "specVersion": "1.6"})
        sbom.write_text(sbom_body, encoding="utf-8")
        binder.bind_sidecar(sidecar_directory, COMPOSITIONS[1].name)
        sidecar = json.loads((sidecar_directory / "evidence-scope.json").read_text(encoding="utf-8"))
        check(
            "sidecar binding does not rewrite the bound document",
            sbom.read_text(encoding="utf-8") == sbom_body,
        )
        check(
            "sidecar names the bound file's measured digest",
            sidecar["boundFiles"]
            == [
                {
                    "file": "sbom-probe.cdx.json",
                    "byteCount": len(sbom_body.encode()),
                    "sha256": hashlib.sha256(sbom_body.encode()).hexdigest(),
                }
            ],
        )
        check("sidecar carries the evidence scope", "evidenceScope" in sidecar)
        check("sidecar is marked provisional today", sidecar["provisional"] is True)
        sbom.write_text(sbom_body + " ", encoding="utf-8")
        binder.bind_sidecar(sidecar_directory, COMPOSITIONS[1].name)
        rebound_sidecar = json.loads(
            (sidecar_directory / "evidence-scope.json").read_text(encoding="utf-8")
        )
        check(
            "a substituted bound file changes the sidecar digest",
            rebound_sidecar["boundFiles"][0]["sha256"] != sidecar["boundFiles"][0]["sha256"],
        )
        check(
            "the sidecar does not bind itself",
            all(entry["file"] != "evidence-scope.json" for entry in rebound_sidecar["boundFiles"]),
        )
    finally:
        shutil.rmtree(directory, ignore_errors=True)

    return report_checks("self-test", checks)


def self_test_commands() -> int:
    """Prove the command-line screen fires, by screening command lines that should fail.

    `command_line_violations` is the guarantee that nothing this script runs can deploy.
    Asserting that over the real invocations only shows it returns empty. These probes take
    a known-good invocation and break it one way at a time.
    """
    checks: list[tuple[str, bool, str]] = []

    def check(name: str, condition: bool, note: str = "") -> None:
        checks.append((name, condition, note))

    good = XcodebuildInvocation(
        action="build",
        scheme=COMPOSITIONS[0].scheme,
        configuration="Debug",
        derived_data=pathlib.Path("/tmp/t151-probe"),
    ).argv
    check("the real invocation is clean", command_line_violations(good) == [], " ".join(good[:4]))

    testing = XcodebuildInvocation(
        action="build-for-testing",
        scheme=COMPOSITIONS[0].scheme,
        configuration="Debug",
        derived_data=pathlib.Path("/tmp/t151-probe"),
    ).argv
    check("the real build-for-testing invocation is clean", command_line_violations(testing) == [])

    def planted(name: str, mutate) -> None:
        argv = list(good)
        mutate(argv)
        violations = command_line_violations(argv)
        check(f"planted: {name}", bool(violations), violations[0] if violations else "NOT CAUGHT")

    planted("test action", lambda argv: argv.__setitem__(1, "test"))
    planted("test-without-building action", lambda argv: argv.__setitem__(1, "test-without-building"))
    planted("archive action", lambda argv: argv.__setitem__(1, "archive"))
    planted("install action", lambda argv: argv.__setitem__(1, "install"))
    planted("-allowProvisioningUpdates", lambda argv: argv.append("-allowProvisioningUpdates"))
    planted("-exportArchive", lambda argv: argv.append("-exportArchive"))
    planted("-authenticationKeyPath", lambda argv: argv.append("-authenticationKeyPath"))
    planted("-skipPackageSignatureValidation", lambda argv: argv.append("-skipPackageSignatureValidation"))
    planted("-resolvePackageDependencies", lambda argv: argv.append("-resolvePackageDependencies"))
    planted(
        "concrete destination by name",
        lambda argv: argv.__setitem__(
            argv.index("-destination") + 1, "platform=iOS Simulator,name=iPhone 15"
        ),
    )
    planted(
        "concrete destination by id",
        lambda argv: argv.__setitem__(
            argv.index("-destination") + 1, "platform=iOS Simulator,id=DEADBEEF"
        ),
    )
    planted(
        "physical device destination",
        lambda argv: argv.__setitem__(
            argv.index("-destination") + 1, "platform=iOS,name=Some iPhone"
        ),
    )
    planted("no destination", lambda argv: [argv.pop(argv.index("-destination") + 1), argv.remove("-destination")])
    planted(
        "signing re-enabled",
        lambda argv: argv.__setitem__(argv.index("CODE_SIGNING_ALLOWED=NO"), "CODE_SIGNING_ALLOWED=YES"),
    )
    planted("a signing identity supplied", lambda argv: argv.append("CODE_SIGN_IDENTITY=Apple Development"))
    planted("a development team supplied", lambda argv: argv.append("DEVELOPMENT_TEAM=ABCDE12345"))
    planted("a provisioning profile supplied", lambda argv: argv.append("PROVISIONING_PROFILE_SPECIFIER=x"))
    planted(
        "shared derived-data path",
        lambda argv: [argv.pop(argv.index("-derivedDataPath") + 1), argv.remove("-derivedDataPath")],
    )
    for flag in OFFLINE_PACKAGE_FLAGS:
        planted(f"offline flag {flag} dropped", lambda argv, flag=flag: argv.remove(flag))
    planted("not xcodebuild at all", lambda argv: argv.__setitem__(0, "simctl"))

    # Non-vacuity of the *exactness* of token matching: these must NOT fire, or the screen
    # would be a substring grep that fails on any path containing a forbidden word.
    for benign in ("/tmp/install-x", "/tmp/archive-x", "/tmp/test-x"):
        argv = list(good)
        argv[argv.index("-derivedDataPath") + 1] = benign
        check(
            f"benign path {benign} is not a violation",
            command_line_violations(argv) == [],
            "; ".join(command_line_violations(argv)),
        )

    # The constructor itself refuses a non-compile action, so a widened action set fails
    # here rather than only in the screen.
    try:
        XcodebuildInvocation(
            action="test",
            scheme=COMPOSITIONS[0].scheme,
            configuration="Debug",
            derived_data=pathlib.Path("/tmp/t151-probe"),
        )
    except ValueError:
        check("XcodebuildInvocation refuses a non-compile action", True)
    else:
        check("XcodebuildInvocation refuses a non-compile action", False, "it accepted 'test'")

    return report_checks("command self-test", checks)


def report_checks(label: str, checks: list[tuple[str, bool, str]]) -> int:
    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, note in checks:
        mark = "ok  " if ok else "FAIL"
        suffix = f"    {note}" if note else ""
        print(f"  {mark} {name}{suffix}")
    print(f"\n{label}: {passed}/{len(checks)} probes behaved as required")
    return 0 if passed == len(checks) else 1


def print_plan() -> int:
    """Every command this pipeline would run, screened, without running any of them."""
    root = pathlib.Path("<run-directory>")
    print("stages: " + ", ".join(STAGES))
    print()
    for configuration, action in (("Debug", "build"), ("Release", "build"), ("Debug", "build-for-testing")):
        for composition in COMPOSITIONS:
            invocation = XcodebuildInvocation(
                action=action,
                scheme=composition.scheme,
                configuration=configuration,
                derived_data=root / "derived" / configuration.lower() / composition.name,
            )
            print(" ".join(invocation.argv))
            violations = command_line_violations(invocation.argv)
            print(f"    screened: {'clean' if not violations else violations}")
    print()
    for script in (
        "check-module-boundaries.py --require-xcode-project",
        "host-test.sh",
        "check-share-extension-target.py --products <products>   (per composition)",
        "check-capability-composition.py --products <products> --expect <composition> --json",
        "check-offline-privacy-archive.py --pixel-only-build <root> --provenance-build <root> --json",
        "audit-release-archives.py --pixel-only-build <root> --provenance-build <root> "
        "--sbom-directory <dir> --json --release-input <file>",
    ):
        print(f"ios/Scripts/{script}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--run-directory",
        type=pathlib.Path,
        help=(
            "where derived data, logs, and artifacts go. Defaults to a temporary directory "
            "named by this run's evidence-scope digests, so two runs under different version "
            "tuples cannot write into one place."
        ),
    )
    parser.add_argument(
        "--stages",
        default=",".join(STAGES),
        help=f"comma-separated subset of: {', '.join(STAGES)}",
    )
    parser.add_argument(
        "--release-artifacts",
        type=pathlib.Path,
        help=(
            "a directory of release artifacts to validate against this run's evidence scope. "
            "Nothing is created, defaulted, or approved: an artifact is accepted only when it "
            "already carries a scope that matches this run whole-tuple."
        ),
    )
    parser.add_argument("--self-test", action="store_true", help="non-vacuity validation")
    parser.add_argument(
        "--self-test-commands",
        action="store_true",
        help="validate the command-line safety screen against planted violations",
    )
    parser.add_argument(
        "--print-plan",
        action="store_true",
        help="print every command this pipeline would run, screened, and run none of them",
    )
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()
    if arguments.self_test_commands:
        return self_test_commands()
    if arguments.print_plan:
        return print_plan()

    requested = tuple(stage.strip() for stage in arguments.stages.split(",") if stage.strip())
    unknown = [stage for stage in requested if stage not in STAGES]
    if unknown:
        print(f"error: unknown stage(s) {unknown}; known: {list(STAGES)}", file=sys.stderr)
        return 2

    if arguments.run_directory is not None:
        run_directory = arguments.run_directory
    else:
        digest = hashlib.sha256(
            "".join(observe_scope(composition).digest for composition in COMPOSITIONS).encode()
        ).hexdigest()[:16]
        run_directory = pathlib.Path(tempfile.gettempdir()) / f"defaike-release-pipeline-{digest}"

    pipeline = Pipeline(
        run_directory=run_directory,
        stages=requested,
        release_artifacts=arguments.release_artifacts,
    )
    return pipeline.run()


if __name__ == "__main__":
    sys.exit(main())
