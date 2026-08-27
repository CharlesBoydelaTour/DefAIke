#!/usr/bin/env python3
"""Software Bill of Materials, notice, corpus, and release-artifact-manifest audit.

Task 14.6. Three audit scripts already exist and this is deliberately not a fourth copy of
any of them:

  * ``check-share-extension-target.py`` (12.2) owns the `.appex`'s forbidden frameworks,
    module symbols, and bundled model artifacts, and exports the one ``strip_swift``.
  * ``check-capability-composition.py`` (12.3) owns adapter version-pin coherence, the closed
    five-package external-dependency allowlist, the 219-file production-source scan for six
    forbidden dependency classes (analytics, advertising, account, custom diagnostics,
    third-party crash reporting, network model updates), both targets' `Info.plist` and
    entitlements key scans, and per-composition archive inspection self-attributed through
    `CFBundleIdentifier`.
  * ``check-offline-privacy-archive.py`` (12.5) owns per-compiled-object symbol attribution
    over every `.o` in both builds, the composition network asymmetry, the archive endpoint
    inventory, the seventh forbidden class (result persistence and export), archive-level
    model delivery, and the vendor static-archive network-stack inventory. It already runs
    12.3 and 12.2 for both compositions.

This script **runs 12.5** — which chains the other two — and requires it to pass, ingesting
its `--json` facts rather than re-deriving them. So the whole "analytics / advertising /
account / crash SDK / identifier / unexpected endpoint / remote-model client /
result-export surface / pixel-only provenance binary" half of task 14.6 is delegated, by
running the checks that own it. Everything below is something none of the three does:

  1. **A Software Bill of Materials.** CycloneDX 1.6 JSON, one document per capability
     composition, covering every resolved package with its pinned version *and resolved
     revision*, the vendored `C2PAC` binary framework with measured per-slice digests, the
     DefAIke module set, and the archive's own file inventory. Nothing generated one before.
  2. **Dependency identity reconciliation, revision included.** 12.3 pins `c2pa-swift`'s
     version in four places and requires the resolved pin to carry *some* revision. This
     requires the exact revision of all five packages, so an unreviewed re-resolve to a
     re-tagged upstream is a finding rather than a silent pass.
  3. **Binary artifact digests.** Nothing in this repository digests a shipped byte. Three
     layers: the `.binaryTarget` checksum declared by the vendor manifest inside the resolved
     checkout, the measured SHA-256 of each extracted xcframework slice, and the measured
     SHA-256 of every file in both bundles.
  4. **Total module attribution.** 12.3 asks whether any `DefAIke*.o` exists; 12.5 attributes
     *symbols* to objects. Neither asks which *package* a non-AI-Buster whole-module object
     came from. Every products-directory object here must attribute to DefAIke or to one
     approved resolved package, so an object from a package nobody approved is a finding.
  5. **Required notices (Requirement 14.5).** The notice subjects one archive owes, derived
     from the packages it measurably ships, checked against what the archive carries.
  6. **Forbidden corpus content (Requirement 14.6).** Content-digest membership against the
     working tree's real evaluation corpus, plus corpus name and directory patterns.
  7. **Privacy manifests.** Every embedded `PrivacyInfo.xcprivacy`, and the absence of a
     first-party one. `NSPrivacyTracking`, `NSPrivacyTrackingDomains`, collected data types,
     and accessed-API reason codes are exactly Requirement 9.13's and 9.18's subject, and no
     existing check reads them.
  8. **A release-record input.** `--release-input` writes the typed evidence task 14.8
     ingests, mapping every finding to one of `archive-audit`, `dependency-notices`,
     `corpus-exclusion`, and `privacy-audit`, with a `GateOutcome` per gate. Five failing
     input classes — unapproved dependency, unapproved binary digest, notice gap, corpus
     artifact, prohibited capability — each produce `failed`. None produces a warning.

Usage:

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    for scheme in DefAIkeApp-PixelOnly DefAIkeApp-PixelPlusProvenance; do
        xcodebuild build -workspace ios/DefAIke.xcworkspace -scheme "$scheme" \\
            -configuration Debug -destination 'generic/platform=iOS Simulator' \\
            -derivedDataPath "/tmp/t146-$scheme" CODE_SIGNING_ALLOWED=NO
    done
    ios/Scripts/audit-release-archives.py \\
        --pixel-only-build /tmp/t146-DefAIkeApp-PixelOnly \\
        --provenance-build /tmp/t146-DefAIkeApp-PixelPlusProvenance \\
        --sbom-directory /tmp/t146-sbom --release-input /tmp/t146-release-input.json

    ios/Scripts/audit-release-archives.py                    # static checks only
    ios/Scripts/audit-release-archives.py --self-test        # non-vacuity, static
    ios/Scripts/audit-release-archives.py --self-test-archives \\
        --pixel-only-build DIR --provenance-build DIR        # non-vacuity, archives

``--pixel-only-build`` and ``--provenance-build`` take the ``-derivedDataPath`` *root*, and
both are Debug roots because 12.5 reads `Build/Products/Debug-iphonesimulator`. Two distinct
roots are mandatory: both schemes build `DefAIke.app` under a shared `PRODUCT_NAME`, so one
shared path means the second build overwrites the first. Each archive is still attributed by
its own `CFBundleIdentifier`, so a swapped pair is a finding.

What this script does not decide. It reaches no licensing conclusion, writes no notice text,
approves no digest baseline, and declares no distribution eligible. Requirement 14.5's notices
are approved documents; where one does not exist this records the gap and the upstream licence
file it would be built from, and nothing here composes prose. The measured binary-digest
baseline is labelled a measurement rather than an approval, and the release-record input
carries the corresponding unprovisioned-input identifiers so the archive-audit gate fails
until a release owner approves them.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

IOS = pathlib.Path(__file__).resolve().parent.parent
REPOSITORY = IOS.parent
SCRIPTS = IOS / "Scripts"


def _load(name: str, filename: str):
    """Import a sibling audit script as a module, so its tables are reused, not restated."""
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# 12.3's composition table, imported rather than restated so the three scripts cannot
# disagree about which bundle identifier is which composition.
_CAPABILITY_CHECK = _load("check_capability_composition", "check-capability-composition.py")
COMPOSITIONS = _CAPABILITY_CHECK.COMPOSITIONS
PIXEL_ONLY, PROVENANCE = COMPOSITIONS[0], COMPOSITIONS[1]
BY_BUNDLE_ID = {c.bundle_identifier: c for c in COMPOSITIONS}


# MARK: - The five failing-input classes

# Requirement 14.6's clause is "treat every unapproved dependency, binary digest, notice gap,
# corpus artifact, or prohibited capability as a failing release record input". These five
# identifiers are that clause, and every finding this script produces carries exactly one of
# them. They are also the raw values of `ArchiveAuditFailingInputClass` in
# `DefAIkeReleaseValidation`, so the JSON this script writes decodes into the typed evidence
# task 14.8 assembles without a translation table in between.
UNAPPROVED_DEPENDENCY = "unapproved-dependency"
UNAPPROVED_BINARY_DIGEST = "unapproved-binary-digest"
NOTICE_GAP = "notice-gap"
CORPUS_ARTIFACT = "corpus-artifact"
PROHIBITED_CAPABILITY = "prohibited-capability"

FAILING_INPUT_CLASSES = [
    UNAPPROVED_DEPENDENCY,
    UNAPPROVED_BINARY_DIGEST,
    NOTICE_GAP,
    CORPUS_ARTIFACT,
    PROHIBITED_CAPABILITY,
]

# Which release-readiness gate each class fails. `ReleaseGate` in `DefAIkeDomain` already has
# exactly the four entries this task produces evidence for, so the mapping is to existing
# identifiers rather than to new ones.
GATE_FOR_CLASS = {
    UNAPPROVED_DEPENDENCY: "archive-audit",
    UNAPPROVED_BINARY_DIGEST: "archive-audit",
    NOTICE_GAP: "dependency-notices",
    CORPUS_ARTIFACT: "corpus-exclusion",
    PROHIBITED_CAPABILITY: "privacy-audit",
}
ALL_GATES = sorted(set(GATE_FOR_CLASS.values()))

# Every release-controlled input this audit can owe, and the gate each one blocks. The raw values
# are the cases of `UnprovisionedArchiveAuditInput`; the mapping is a table rather than a chain of
# conditionals because a gate that silently inherited every owed input would fail for reasons it
# does not depend on, and a release owner reading the record could not tell which artifact to
# produce. An owed input is never a warning: `release_record_input` turns it into `failed`, on the
# principle Requirement 14.15 states — a missing mandatory entry blocks distribution.
OWED_INPUTS_FOR_GATE: dict[str, set[str]] = {
    "archive-audit": {
        "approved-binary-artifact-digest-baseline",
        "approved-external-dependency-allowlist-artifact",
        "distribution-archive",
    },
    "dependency-notices": {"approved-application-notice-artifacts"},
    "corpus-exclusion": {"produced-initial-model-bundle-artifact-tree"},
    "privacy-audit": {"first-party-privacy-manifest"},
}
ALL_OWED_INPUTS = {
    identifier for inputs in OWED_INPUTS_FOR_GATE.values() for identifier in inputs
}


# MARK: - Approved dependency identities

class ApprovedPackage:
    """One external package a production or test graph may resolve, pinned to fixed bytes.

    12.3's allowlist answers "may this package be here at all". This one additionally answers
    "at exactly which bytes", because a version tag can be moved and a resolve nobody reviewed
    is how a reviewed dependency becomes an unreviewed one without any manifest changing.
    """

    def __init__(
        self,
        identity: str,
        version: str,
        revision: str,
        ships: bool,
        why: str,
        licence_files: list[str],
    ) -> None:
        self.identity = identity
        self.version = version
        self.revision = revision
        self.ships = ships
        self.why = why
        self.licence_files = licence_files


# The versions come from the design and from `Package.swift`'s `exact:` pins; the revisions come
# from `Package.resolved`, which `ios/.gitignore` tracks deliberately as "part of the dependency
# reconciliation record". Requiring both here cross-checks two tracked files against a third
# constant, so a re-resolve that changed either is a finding.
#
# Limit, stated rather than implied: an edit that changed the manifest, the resolved file, and
# this table together would pass. What this catches is an *unreviewed* resolve, which is the
# failure that actually happens.
APPROVED_PACKAGES = [
    ApprovedPackage(
        identity="swift-property-based",
        version="2.0.0",
        revision="f5b24d3a0468d688934405a9cba9516cb17be2ec",
        ships=False,
        why="test-only property-based toolchain; linked into no shipping product",
        licence_files=["LICENSE"],
    ),
    ApprovedPackage(
        identity="c2pa-swift",
        version="0.0.12",
        revision="a2812bdebcff324aa68fecba804e10e2144d5e4f",
        ships=True,
        why="the reviewed Content Credential validator; pixel-plus-provenance only",
        licence_files=["LICENSE-MIT", "LICENSE-APACHE"],
    ),
    ApprovedPackage(
        identity="swift-crypto",
        version="3.15.1",
        revision="95ba0316a9b733e92bb6b071255ff46263bbe7dc",
        ships=True,
        why="transitive dependency of c2pa-swift",
        licence_files=["LICENSE.txt", "NOTICE.txt"],
    ),
    ApprovedPackage(
        identity="swift-certificates",
        version="1.19.4",
        revision="449dbbecd0f31e82b510ada227ca152caa8b5e98",
        ships=True,
        why="transitive dependency of c2pa-swift",
        licence_files=["LICENSE.txt", "NOTICE.txt"],
    ),
    ApprovedPackage(
        identity="swift-asn1",
        version="1.7.1",
        revision="a9a5efd40eaf558a2bcd48d64b1d1646be686008",
        ships=True,
        why="transitive dependency of c2pa-swift and swift-certificates",
        licence_files=["LICENSE.txt", "NOTICE.txt"],
    ),
]
APPROVED_BY_IDENTITY = {package.identity: package for package in APPROVED_PACKAGES}


# MARK: - Approved binary artifact digests

# The one binary artifact either composition ships, in three layers.
#
# `declaredChecksum` is the value `c2pa-swift`'s own manifest publishes for the xcframework
# zip. Pinning it here and requiring the resolved checkout's manifest to agree is a real
# cross-check: a substituted checkout is a finding.
#
# `sliceDigests` are **measurements taken by this task**, not approvals. SwiftPM does not retain
# the downloaded zip, so `declaredChecksum` cannot be recomputed from a build tree; what can be
# measured is the extracted slice, and pinning that measurement means a substituted or
# recompiled slice fails immediately. It is labelled a baseline everywhere it appears, and the
# release-record input carries `approved-binary-artifact-digest-baseline` as an unprovisioned
# input so the archive-audit gate fails until a release owner approves it.
VENDORED_BINARY_ARTIFACT = {
    "name": "C2PAC",
    "package": "c2pa-swift",
    "declaredChecksum": "a038bc316f7a890d1233e156cc743854cee98e24359a6176fb107088359fe0a8",
    "declaredURL": (
        "https://github.com/contentauth/c2pa-swift/releases/download/v0.0.12/"
        "C2PAC.xcframework.zip"
    ),
    "sliceDigests": {
        "ios-arm64": {
            "sha256": "de14c673d499b4c7142f1fdc69de61c3d4eac5365bd414ec8d53892d729cd6b7",
            "byteCount": 210192216,
        },
        "ios-arm64_x86_64-simulator": {
            "sha256": "f2cb1809ac188972839d419a680df8014d57b9c4df0a72b3bf974603e06f7852",
            "byteCount": 420136016,
        },
    },
    "approvalStatus": "measured-baseline-not-release-approved",
}

# The required pixel model's weight-blob digest (Requirement 10.4), and the constant the domain
# layer carries it in. Cross-checked rather than restated, so the two cannot drift.
REQUIRED_WEIGHT_DIGEST = "f073f8a325f63e35ef0668c985ac762486a1b50e57dcf5ae33d4647bd26d4c1e"
REQUIRED_CHECKPOINT = "Thermostatic/community-forensics-low-quality-detector-2026-08"

# Relative to an `ios` root rather than absolute, so the self-test's copied tree is the tree
# actually read. An absolute constant here would have made the two model-identity probes
# silently vacuous — they would have read the unmodified repository and reported nothing — which
# is exactly the failure mode the self-test exists to catch, and it did catch it.
MODEL_IDENTITY_RELATIVE = pathlib.PurePath(
    "DefAIkePackage", "Sources", "DefAIkeDomain", "ReleaseArtifacts",
    "ModelBundleManifest.swift",
)


# MARK: - Notices

# The notice subject the Lowq checkpoint owes, and the upstream attribution the compiled model
# itself records. `data/coreml/commfor-lowq-384.mlmodelc/coremldata.bin` carries
# `MLModelAuthorKey` = "derived from Thermostatic/community-forensics (MIT)", so the subject and
# its upstream terms are a measured fact about the artifact rather than a claim written here.
CHECKPOINT_NOTICE_SUBJECT = "lowq-checkpoint"
CHECKPOINT_UPSTREAM = "Thermostatic/community-forensics"

# Where a notice would live in a bundle. Any of these is accepted, because the layout is a
# release-artifact decision this script does not own; what it requires is that a notice for
# each owed subject be *present and non-empty* somewhere a distributed bundle carries.
NOTICE_DIRECTORY_NAMES = ["Notices", "notices", "Licenses", "licenses", "Acknowledgements"]
NOTICE_FILE_PATTERN = re.compile(
    r"(licen[cs]e|notice|attribution|acknowledg|copyright)", re.IGNORECASE
)


# MARK: - Forbidden corpus content

# The working tree's real evaluation corpus and detector-weight caches. `/data/` is untracked
# (`.gitignore` line 2), so none of this is in version control and all of it is on disk: 10,832
# corpus images across three source directories and 2.4 GB of cached detector weights and index
# tables. Requirement 14.6 requires the application and Model Bundle to contain none of it.
CORPUS_ROOTS = ["data/images", "data/cache"]

# Name and directory fragments that identify corpus content by path rather than by content.
# Derived from the actual filenames on disk, not from generic extensions: an app legitimately
# ships `.png`, so banning an extension would be both over- and under-inclusive.
CORPUS_PATH_FRAGMENTS = [
    "openfaketiny",
    "oft_reddit_",
    "rewind_no_ammeba",
    "ReWIND",
    "sofake_ood",
    "commfor-lowq",
    "clipbased_clipdet",
    "corvi2023",
    "metadata_probe",
]

# Extensions no distributed bundle has any reason to carry, and every one of which the corpus
# and the detector caches use. Checked as a second, independent signal from content digests.
CORPUS_EXTENSIONS = [".parquet", ".npy", ".pth", ".zip", ".csv"]


# MARK: - Privacy manifests

# Requirement 9.13 forbids analytics and advertising identifiers and Requirement 9.18 makes the
# Release Process verify their absence. A privacy manifest is where iOS declares exactly that,
# and no existing check reads one. Reason codes and data categories below are Apple's spelling.
FORBIDDEN_PRIVACY_DATA_TYPES = [
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypeAdvertisingData",
    "NSPrivacyCollectedDataTypeCrashData",
    "NSPrivacyCollectedDataTypePerformanceData",
    "NSPrivacyCollectedDataTypeOtherDiagnosticData",
    "NSPrivacyCollectedDataTypeProductInteraction",
    "NSPrivacyCollectedDataTypePhotosorVideos",
    "NSPrivacyCollectedDataTypeUserID",
    "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypeName",
    "NSPrivacyCollectedDataTypePreciseLocation",
    "NSPrivacyCollectedDataTypeCoarseLocation",
]
FORBIDDEN_PRIVACY_API_TYPES = [
    "NSPrivacyAccessedAPICategoryUserDefaults",
    "NSPrivacyAccessedAPICategoryActiveKeyboards",
    "NSPrivacyAccessedAPICategoryDiskSpace",
]


# MARK: - Findings

class Report:
    """Collects class-tagged findings, observations, and measured facts.

    Every finding carries one of the five failing-input classes, so the release-record input
    can be derived from the findings rather than assembled a second time by hand. There is no
    `warn` member: Requirement 14.6's clause makes each class a failure, and a reporting
    surface that could downgrade one would be the way that clause stops holding.
    """

    def __init__(self, quiet: bool = False) -> None:
        self.findings: list[dict] = []
        self.observations: list[dict] = []
        self.facts: dict = {}
        self.unprovisioned: list[str] = []
        self.quiet = quiet

    def fail(self, input_class: str, message: str) -> None:
        assert input_class in FAILING_INPUT_CLASSES, input_class
        self.findings.append({"class": input_class, "message": message})

    def require(self, condition: bool, input_class: str, message: str) -> None:
        if not condition:
            self.fail(input_class, message)

    def observe(self, kind: str, **fields: object) -> None:
        self.observations.append({"kind": kind, **fields})

    def owe(self, identifier: str) -> None:
        """Record a release-controlled input this repository does not carry.

        A separate list from findings, and a raw value in
        ``UnprovisionedArchiveAuditInput``, because the two are closed by different work: a
        finding is fixed by changing the build, and an owed input is fixed by a release owner
        producing an artifact. Both make a gate fail; only one is a defect.
        """
        assert identifier in ALL_OWED_INPUTS, identifier
        if identifier not in self.unprovisioned:
            self.unprovisioned.append(identifier)

    def say(self, message: str) -> None:
        if not self.quiet:
            print(message)

    def messages(self) -> list[str]:
        return [f"{finding['class']}: {finding['message']}" for finding in self.findings]


def digest_of(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def run_tool(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"{command[1]} failed")
    return result.stdout


# MARK: - Layer 0: delegate the three existing audits

def delegate_existing_audits(
    builds: dict[str, pathlib.Path | None], report: Report
) -> None:
    """Run 12.5's audit — which runs 12.3's and 12.2's — and require it to pass.

    Delegation rather than duplication, and running rather than citing. Every claim about
    analytics, advertising, account, crash-reporting, custom-diagnostic, and model-update
    dependency classes, every identifier and plist-key scan, the endpoint inventory, the
    result-export class, the pixel-only provenance-binary absence, and the offline asymmetry
    stays owned by the script that measured it. What this adds is that a regression in any of
    them lands in *this* task's release-record input under `prohibited-capability`, instead of
    being invisible to a release record assembled only from 14.6's output.

    `check-module-boundaries.py` is deliberately not run here. It is the declared module
    closure's audit, a release verifier runs it separately, and it needs `--require-xcode-
    project`; adding a fourth invocation of it would produce two authorities for one claim.
    """
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
        json_path = pathlib.Path(handle.name)
    command = [
        sys.executable,
        str(SCRIPTS / "check-offline-privacy-archive.py"),
        "--json",
        str(json_path),
    ]
    if all(path is not None for path in builds.values()):
        command += [
            "--pixel-only-build",
            str(builds[PIXEL_ONLY.name]),
            "--provenance-build",
            str(builds[PROVENANCE.name]),
        ]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    try:
        delegated = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report.fail(
            PROHIBITED_CAPABILITY,
            f"12.5's audit produced no readable JSON: {error}",
        )
        delegated = {"findings": ["<unreadable>"], "observations": [], "facts": {}}
    finally:
        json_path.unlink(missing_ok=True)

    for finding in delegated["findings"]:
        report.fail(
            PROHIBITED_CAPABILITY,
            f"delegated (12.2/12.3/12.5): {finding}",
        )
    report.require(
        result.returncode == 0,
        PROHIBITED_CAPABILITY,
        f"check-offline-privacy-archive.py exited {result.returncode} with no reported "
        "finding, so the delegated audit failed for a reason it did not record",
    )
    report.facts["delegated.offlinePrivacyArchive"] = delegated["facts"]
    report.facts["delegated.findingCount"] = len(delegated["findings"])
    report.facts["delegated.observationCount"] = len(delegated["observations"])
    # The delegated observations are carried through verbatim. Task 14.8 needs the Provenance
    # Feasibility Gate inputs 12.3 and 12.5 classified as observations — the statically linked
    # Rust HTTP/2 and TLS stack, the compiled-in OCSP client, the absent bundled model — and
    # re-deriving or re-classifying them here would create a second, divergent record of a
    # decision another task already made correctly.
    for observation in delegated["observations"]:
        report.observe("delegated-offline-privacy-observation", delegated=observation)
    report.say(
        f"  12.5's audit (which runs 12.3's and 12.2's): {len(delegated['findings'])} "
        f"finding(s), {len(delegated['observations'])} observation(s), exit {result.returncode}"
    )


# MARK: - Layer 1: dependency identity, version and revision

def resolved_pins(root: pathlib.Path, report: Report) -> dict[str, dict]:
    path = root / "DefAIkePackage" / "Package.resolved"
    try:
        resolved = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report.fail(UNAPPROVED_DEPENDENCY, f"Package.resolved is unreadable: {error}")
        return {}
    pins: dict[str, dict] = {}
    for entry in resolved.get("pins", []):
        identity = entry.get("identity", "")
        if identity in pins:
            report.fail(
                UNAPPROVED_DEPENDENCY,
                f"Package.resolved records {identity} more than once",
            )
        pins[identity] = entry
    return pins


def check_dependency_identities(root: pathlib.Path, report: Report) -> None:
    """Require every resolved package to match an approved identity, version, and revision."""
    pins = resolved_pins(root, report)
    if not pins:
        return

    for identity, entry in sorted(pins.items()):
        approved = APPROVED_BY_IDENTITY.get(identity)
        if approved is None:
            report.fail(
                UNAPPROVED_DEPENDENCY,
                f"{identity} is resolved but has no approved entry; every dependency, "
                "transitive ones included, needs one, and an unlisted package is how an "
                "analytics, advertising, account, diagnostic, crash-reporting, or "
                "model-update client arrives",
            )
            continue
        state = entry.get("state", {})
        report.require(
            state.get("version") == approved.version,
            UNAPPROVED_DEPENDENCY,
            f"{identity} resolves to version {state.get('version')!r}, approved "
            f"{approved.version!r}",
        )
        report.require(
            state.get("revision") == approved.revision,
            UNAPPROVED_DEPENDENCY,
            f"{identity} resolves to revision {state.get('revision')!r}, approved "
            f"{approved.revision!r}; a version tag can be moved, so the revision is what "
            "binds the pin to fixed bytes",
        )

    missing = sorted(set(APPROVED_BY_IDENTITY) - set(pins))
    report.require(
        not missing,
        UNAPPROVED_DEPENDENCY,
        f"approved dependency entries {missing} resolve to nothing; a stale approval is how a "
        "name gets reused later for something else",
    )
    report.facts["resolvedPackages"] = {
        identity: {
            "version": entry.get("state", {}).get("version"),
            "revision": entry.get("state", {}).get("revision"),
        }
        for identity, entry in sorted(pins.items())
    }
    report.say(
        f"  {len(pins)} resolved package(s), each matched to an approved version and revision"
    )


def package_module_map(build_root: pathlib.Path, report: Report) -> dict[str, str]:
    """Which package each non-AI-Buster module belongs to, read from the resolved checkouts.

    Derived rather than tabulated: each checkout's own manifest names the targets it defines,
    and a target name is the module name a whole-module object is written under. Parsing
    `.target(name:)`, `.binaryTarget(name:)`, and `.executableTarget(name:)` specifically —
    never `.product(name:package:)` — matters because `swift-crypto`'s manifest names
    `SwiftASN1` as a product of another package, and treating that as its own target would
    attribute `SwiftASN1.o` to the wrong package.
    """
    checkouts = build_root / "SourcePackages" / "checkouts"
    mapping: dict[str, str] = {}
    if not checkouts.is_dir():
        report.observe(
            "package-module-map-unavailable",
            searched=str(checkouts),
            note=(
                "This build has no SourcePackages/checkouts directory, so module-to-package "
                "attribution could not be derived and the total-attribution requirement "
                "below is reported as unmeasured rather than as passing."
            ),
        )
        return mapping
    pattern = re.compile(
        r"\.(?:binaryTarget|executableTarget|target)\(\s*name:\s*\"([A-Za-z0-9_]+)\""
    )
    for checkout in sorted(checkouts.iterdir()):
        manifest = checkout / "Package.swift"
        if not manifest.is_file():
            continue
        for module in pattern.findall(manifest.read_text(encoding="utf-8")):
            mapping.setdefault(module, checkout.name)
    return mapping


def check_module_attribution(
    composition_name: str, build_root: pathlib.Path, report: Report
) -> set[str]:
    """Require every products-directory whole-module object to attribute to an approved owner.

    12.3 asks whether any `DefAIke*.o` exists, so it can tell an unattributable inspection
    from an attributable one. 12.5 attributes *symbols* to objects. Neither asks which package
    a non-AI-Buster object came from, which is the question a bill of materials has to answer:
    `C2PA.o`, `Crypto.o`, `SwiftASN1.o`, and `X509.o` sit in the same directory as
    `DefAIkeDomain.o`, and an object from a package nobody approved would sit there too.

    Returns the set of packages this composition measurably ships, which is what the notice
    requirement below is derived from rather than asserted about.
    """
    products = build_root / "Build" / "Products" / "Debug-iphonesimulator"
    objects = sorted(products.glob("*.o"))
    report.require(
        bool(objects),
        UNAPPROVED_DEPENDENCY,
        f"{composition_name}: {products} contains no whole-module objects, so no module could "
        "have been attributed to a package and this check would pass without measuring",
    )
    mapping = package_module_map(build_root, report)
    shipped: set[str] = set()
    unattributed: list[str] = []
    for path in objects:
        module = path.stem
        if module.startswith("DefAIke"):
            continue
        package = mapping.get(module)
        if package is None:
            unattributed.append(module)
            continue
        if package not in APPROVED_BY_IDENTITY:
            report.fail(
                UNAPPROVED_DEPENDENCY,
                f"{composition_name}: module {module} belongs to package {package}, which has "
                "no approved entry",
            )
            continue
        shipped.add(package)
    report.require(
        not unattributed,
        UNAPPROVED_DEPENDENCY,
        f"{composition_name}: modules {sorted(unattributed)} could not be attributed to any "
        "resolved package; an object nobody can name the origin of is exactly what a bill of "
        "materials exists to refuse",
    )

    # Resource bundles name their package directly, which is a second and independent signal.
    app = products / "DefAIke.app"
    bundle_packages = set()
    if app.is_dir():
        for bundle in sorted(app.glob("*.bundle")):
            head = bundle.stem.split("_", 1)[0]
            if head != "DefAIkePackage":
                bundle_packages.add(head)
    for package in sorted(bundle_packages - set(APPROVED_BY_IDENTITY)):
        report.fail(
            UNAPPROVED_DEPENDENCY,
            f"{composition_name}: embedded resource bundle names unapproved package {package}",
        )
    shipped |= bundle_packages & set(APPROVED_BY_IDENTITY)

    for package in sorted(shipped):
        report.require(
            APPROVED_BY_IDENTITY[package].ships,
            UNAPPROVED_DEPENDENCY,
            f"{composition_name} ships {package}, which is approved as nonshipping; a "
            "test-only dependency in a distributed archive is a supply-chain change nobody "
            "reviewed",
        )
    report.facts[f"{composition_name}.shippedPackages"] = sorted(shipped)
    report.facts[f"{composition_name}.wholeModuleObjects"] = sorted(p.stem for p in objects)
    report.say(
        f"  {composition_name}: {len(objects)} whole-module object(s), "
        f"ships {sorted(shipped) or 'no external package'}"
    )
    return shipped


# MARK: - Layer 2: binary artifact digests

def check_binary_artifact(build_root: pathlib.Path, report: Report) -> list[dict]:
    """Reconcile the vendored binary framework's declared checksum and measured slice digests.

    Three layers, because each catches a different substitution:

      * the checksum the resolved checkout's own manifest declares, against the pinned value —
        catches a substituted or edited checkout;
      * the measured SHA-256 of each extracted slice, against the measured baseline — catches a
        substituted, recompiled, or truncated binary; and
      * the presence of both required iOS slices — catches a partially extracted artifact whose
        absence would make the other two checks pass over nothing.

    The zip `declaredChecksum` refers to is not retained by SwiftPM, so it cannot be recomputed
    from a build tree. That limit is recorded rather than papered over, and it is why the slice
    measurement exists at all.
    """
    checkouts = build_root / "SourcePackages" / "checkouts" / VENDORED_BINARY_ARTIFACT["package"]
    manifest = checkouts / "Package.swift"
    if manifest.is_file():
        source = manifest.read_text(encoding="utf-8")
        declared = re.search(
            r"\.binaryTarget\(\s*name:\s*\""
            + re.escape(VENDORED_BINARY_ARTIFACT["name"])
            + r"\",\s*url:\s*\"([^\"]+)\",\s*checksum:\s*\"([0-9a-f]{64})\"",
            source,
        )
        if declared is None:
            report.fail(
                UNAPPROVED_BINARY_DIGEST,
                f"{manifest} declares no checksummed binaryTarget for "
                f"{VENDORED_BINARY_ARTIFACT['name']}; an unchecksummed binary artifact is an "
                "unverifiable dependency",
            )
        else:
            report.require(
                declared.group(1) == VENDORED_BINARY_ARTIFACT["declaredURL"],
                UNAPPROVED_BINARY_DIGEST,
                f"{VENDORED_BINARY_ARTIFACT['name']} is declared at URL "
                f"{declared.group(1)!r}, approved {VENDORED_BINARY_ARTIFACT['declaredURL']!r}",
            )
            report.require(
                declared.group(2) == VENDORED_BINARY_ARTIFACT["declaredChecksum"],
                UNAPPROVED_BINARY_DIGEST,
                f"{VENDORED_BINARY_ARTIFACT['name']} declares checksum "
                f"{declared.group(2)}, approved "
                f"{VENDORED_BINARY_ARTIFACT['declaredChecksum']}",
            )
    else:
        report.observe(
            "vendor-manifest-unavailable",
            searched=str(manifest),
            note=(
                "This build has no c2pa-swift checkout, so the declared binaryTarget checksum "
                "was not cross-checked in this run."
            ),
        )

    artifacts = (
        build_root / "SourcePackages" / "artifacts" / VENDORED_BINARY_ARTIFACT["package"]
        / VENDORED_BINARY_ARTIFACT["name"]
    )
    measured: list[dict] = []
    found_slices: set[str] = set()
    for slice_name, expected in sorted(VENDORED_BINARY_ARTIFACT["sliceDigests"].items()):
        binary = (
            artifacts
            / f"{VENDORED_BINARY_ARTIFACT['name']}.xcframework"
            / slice_name
            / f"{VENDORED_BINARY_ARTIFACT['name']}.framework"
            / VENDORED_BINARY_ARTIFACT["name"]
        )
        if not binary.is_file():
            continue
        found_slices.add(slice_name)
        size = binary.stat().st_size
        actual = digest_of(binary)
        report.require(
            size == expected["byteCount"],
            UNAPPROVED_BINARY_DIGEST,
            f"{VENDORED_BINARY_ARTIFACT['name']} {slice_name} is {size} bytes, baseline "
            f"{expected['byteCount']}",
        )
        report.require(
            actual == expected["sha256"],
            UNAPPROVED_BINARY_DIGEST,
            f"{VENDORED_BINARY_ARTIFACT['name']} {slice_name} digests to {actual}, baseline "
            f"{expected['sha256']}",
        )
        measured.append(
            {
                "slice": slice_name,
                "byteCount": size,
                "sha256": actual,
                "matchesBaseline": actual == expected["sha256"],
            }
        )
        report.say(f"  {VENDORED_BINARY_ARTIFACT['name']} {slice_name}: {size} bytes, {actual}")

    if artifacts.is_dir():
        report.require(
            found_slices == set(VENDORED_BINARY_ARTIFACT["sliceDigests"]),
            UNAPPROVED_BINARY_DIGEST,
            f"{VENDORED_BINARY_ARTIFACT['name']} extracted only {sorted(found_slices)}; both "
            f"{sorted(VENDORED_BINARY_ARTIFACT['sliceDigests'])} are required, and a missing "
            "slice would make the digest comparison pass over nothing",
        )
        # The baseline is a measurement, not an approval, so the release-record input owes the
        # approval regardless of whether the comparison matched.
        report.owe("approved-binary-artifact-digest-baseline")
        report.observe(
            "binary-artifact-digest-baseline",
            requirements=["14.5", "14.6", "10.5"],
            artifact=VENDORED_BINARY_ARTIFACT["name"],
            package=VENDORED_BINARY_ARTIFACT["package"],
            declaredChecksum=VENDORED_BINARY_ARTIFACT["declaredChecksum"],
            declaredURL=VENDORED_BINARY_ARTIFACT["declaredURL"],
            measuredSlices=measured,
            approvalStatus=VENDORED_BINARY_ARTIFACT["approvalStatus"],
            note=(
                "The slice digests above are measurements taken by task 14.6, not a release "
                "approval. SwiftPM does not retain the downloaded xcframework zip, so the "
                "vendor-declared checksum cannot be recomputed from a build tree; the slice "
                "measurement is what can be re-verified, and pinning it means a substituted "
                "or recompiled binary fails. Until a release owner approves the baseline, "
                "`approved-binary-artifact-digest-baseline` keeps the archive-audit gate "
                "failing."
            ),
        )
    report.facts["vendorBinaryArtifactSlices"] = measured
    return measured


def check_model_weight_digest(root: pathlib.Path, report: Report) -> dict:
    """Reconcile Requirement 10.4's weight digest against the domain constant and the artifact.

    Three statements, and they are different statements:

      * the domain layer's `RequiredPixelModel.weightDigestHexadecimal` must equal the value
        Requirement 10.4 fixes — a cross-check between this script and the shipping constant;
      * the compiled model in the working tree, when present, must digest to that value; and
      * neither archive contains it, which 12.5 already recorded as `bundled-model-absent`
        and which is carried through rather than re-classified.
    """
    facts: dict = {"requiredWeightDigest": REQUIRED_WEIGHT_DIGEST}
    model_source = root / MODEL_IDENTITY_RELATIVE
    if model_source.is_file():
        source = model_source.read_text(encoding="utf-8")
        report.require(
            REQUIRED_WEIGHT_DIGEST in source,
            UNAPPROVED_BINARY_DIGEST,
            f"{model_source.name} does not carry the required weight digest "
            f"{REQUIRED_WEIGHT_DIGEST}; the audit and the shipping constant have drifted",
        )
        report.require(
            REQUIRED_CHECKPOINT in source,
            UNAPPROVED_DEPENDENCY,
            f"{model_source.name} does not name the required checkpoint "
            f"{REQUIRED_CHECKPOINT}",
        )
    else:
        report.fail(
            UNAPPROVED_BINARY_DIGEST,
            f"{model_source} does not exist, so the required weight digest could not "
            "be cross-checked against the shipping constant",
        )

    weights = root.parent / "data" / "coreml" / "commfor-lowq-384.mlmodelc" / "weights"
    blob = weights / "weight.bin"
    if blob.is_file():
        measured = digest_of(blob)
        facts["measuredWeightDigest"] = measured
        facts["measuredWeightByteCount"] = blob.stat().st_size
        report.require(
            measured == REQUIRED_WEIGHT_DIGEST,
            UNAPPROVED_BINARY_DIGEST,
            f"the compiled model weight blob digests to {measured}, and Requirement 10.4 "
            f"fixes {REQUIRED_WEIGHT_DIGEST}",
        )
        report.say(
            f"  model weight blob: {blob.stat().st_size} bytes, {measured} "
            f"({'matches' if measured == REQUIRED_WEIGHT_DIGEST else 'DIFFERS FROM'} "
            "Requirement 10.4)"
        )
    else:
        report.observe(
            "model-weight-artifact-absent",
            requirements=["10.4"],
            searched=str(blob),
            note=(
                "The compiled model is untracked working-tree content under `/data/`, so a "
                "clean checkout has none and the digest reconciliation above is limited to "
                "the shipping constant."
            ),
        )
        report.say("  model weight blob: not present in this working tree")
    report.facts["modelWeightDigest"] = facts
    return facts


# MARK: - Layer 3: the release artifact manifest

def bundles_in(app: pathlib.Path) -> list[pathlib.Path]:
    """The application bundle and every extension bundle inside it.

    Requirement 14.6 names "the application and Model Bundle", and Requirement 14.5 names
    "each distributed application"; the Share Extension is a separately signed bundle inside
    the app, so it is inventoried and checked as its own unit rather than folded into the app's
    file list. A finding that says only "somewhere in the archive" would not tell a release
    owner which signed bundle to fix.
    """
    return [app] + sorted(app.rglob("*.appex"))


def inventory_bundle(bundle: pathlib.Path) -> list[dict]:
    """Every file in one bundle, with its size and content digest.

    This is the release artifact manifest Requirement 14.6 verifies corpus absence *from*.
    Nothing in this repository produced one, and the two archive audits that exist read symbol
    tables and string data rather than file content, so no digest of a shipped byte existed
    before this.
    """
    entries: list[dict] = []
    for path in sorted(bundle.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        # Files inside a nested `.appex` belong to that bundle's inventory, not the app's.
        if bundle.suffix == ".app" and any(
            parent.suffix == ".appex" for parent in path.parents
        ):
            continue
        entries.append(
            {
                "path": str(path.relative_to(bundle)),
                "byteCount": path.stat().st_size,
                "sha256": digest_of(path),
            }
        )
    return entries


# MARK: - Layer 4: required notices

def observed_licence_files(build_root: pathlib.Path, package: ApprovedPackage) -> list[dict]:
    """The upstream licence files a package's resolved checkout carries, measured.

    Recorded so a notice gap names the source a notice would be built from. Deliberately not
    used to *compose* a notice: Requirement 14.5's notices are approved documents, and reading
    a licence file is not approving its use.
    """
    checkout = build_root / "SourcePackages" / "checkouts" / package.identity
    observed: list[dict] = []
    for name in package.licence_files:
        path = checkout / name
        if path.is_file():
            observed.append(
                {
                    "file": name,
                    "byteCount": path.stat().st_size,
                    "sha256": digest_of(path),
                }
            )
    return observed


def check_required_notices(
    composition_name: str,
    build_root: pathlib.Path,
    shipped: set[str],
    inventories: dict[str, list[dict]],
    report: Report,
) -> dict:
    """Require a notice in the archive for the checkpoint and for every shipped dependency.

    Requirement 14.5. The owed subject set is *derived from what the archive measurably ships*
    rather than from a list written here: the packages come from `check_module_attribution`'s
    whole-module objects and embedded resource bundles, and the checkpoint subject is owed by
    every distributed application because Requirement 10.1 packages the Initial Model Bundle
    inside it.

    Nothing here writes notice text. A missing notice is a finding with the upstream licence
    file it would be built from recorded beside it, and the corresponding unprovisioned input
    is owed so the dependency-notices gate fails until an approved notice artifact exists.
    """
    owed: list[dict] = [
        {
            "subject": CHECKPOINT_NOTICE_SUBJECT,
            "requires": "Requirement 14.5, attribution for the Lowq checkpoint",
            "upstreamAttribution": (
                f"the compiled model records MLModelAuthorKey 'derived from "
                f"{CHECKPOINT_UPSTREAM} (MIT)'"
            ),
            "observedLicenceFiles": [],
        }
    ]
    for identity in sorted(shipped):
        package = APPROVED_BY_IDENTITY[identity]
        owed.append(
            {
                "subject": identity,
                "requires": f"Requirement 14.5, attribution for bundled dependency {identity}",
                "upstreamAttribution": package.why,
                "observedLicenceFiles": observed_licence_files(build_root, package),
            }
        )

    present: dict[str, list[str]] = {}
    for bundle_name, entries in inventories.items():
        found = [
            entry["path"]
            for entry in entries
            if entry["byteCount"] > 0
            and (
                NOTICE_FILE_PATTERN.search(pathlib.PurePath(entry["path"]).name)
                or any(
                    part in NOTICE_DIRECTORY_NAMES
                    for part in pathlib.PurePath(entry["path"]).parts[:-1]
                )
            )
        ]
        if found:
            present[bundle_name] = sorted(found)

    for entry in owed:
        # A notice is matched by its subject appearing in a notice file's path. Deliberately
        # coarse: the bundle layout is a release-artifact decision this script does not own, so
        # it requires presence rather than a location.
        matched = sorted(
            f"{bundle}:{path}"
            for bundle, paths in present.items()
            for path in paths
            if entry["subject"].lower() in path.lower()
        )
        entry["presentAt"] = matched
        report.require(
            bool(matched),
            NOTICE_GAP,
            f"{composition_name}: no notice for {entry['subject']} is present in any bundle "
            f"({entry['requires']}); "
            + (
                "the archive carries no notice file at all"
                if not present
                else f"the archive's notice files are {json.dumps(present, sort_keys=True)}"
            ),
        )

    if not present:
        report.owe("approved-application-notice-artifacts")
    report.facts[f"{composition_name}.owedNotices"] = owed
    report.facts[f"{composition_name}.presentNoticeFiles"] = present
    report.say(
        f"  {composition_name}: {len(owed)} owed notice subject(s), "
        f"{sum(len(v) for v in present.values())} notice file(s) present"
    )
    return {"owed": owed, "present": present}


# MARK: - Layer 5: forbidden corpus content

def corpus_size_index(repository: pathlib.Path, report: Report) -> tuple[dict[int, list[pathlib.Path]], int]:
    """Index the working tree's evaluation corpus by file size.

    Why size first and digest second. The corpus on disk is 7.5 GB of images plus 2.4 GB of
    cached detector weights and index tables — 10,832 image files across three source
    directories. Digesting all of it on every run would cost minutes for a question whose
    answer is decided by a few dozen archive files. Two identical files necessarily have the
    same size, so a size index is an exact prefilter: only a corpus file whose size matches an
    archive file's is ever digested, and a digest match is still the thing that decides.

    Returns the index and the number of corpus files it covers, so a run over a checkout with
    no corpus reports that it measured nothing instead of reporting a clean pass.
    """
    index: dict[int, list[pathlib.Path]] = {}
    counted = 0
    for relative in CORPUS_ROOTS:
        root = repository / relative
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            counted += 1
            index.setdefault(path.stat().st_size, []).append(path)
    if counted == 0:
        report.observe(
            "corpus-not-present-in-working-tree",
            requirements=["14.6"],
            searched=[str(repository / relative) for relative in CORPUS_ROOTS],
            note=(
                "`/data/` is untracked, so a clean checkout carries no corpus and the "
                "content-digest half of the corpus exclusion check has nothing to compare "
                "against. The path-fragment and extension checks below still run, and this "
                "observation records that the strongest half did not."
            ),
        )
    return index, counted


def check_corpus_exclusion(
    composition_name: str,
    inventories: dict[str, list[dict]],
    index: dict[int, list[pathlib.Path]],
    corpus_file_count: int,
    repository: pathlib.Path,
    report: Report,
) -> None:
    """Require no bundle to contain evaluation-corpus content, by digest, name, or extension.

    Requirement 14.6 verifies from the release artifact manifest that non-distributable
    evaluation-corpus content is absent from the application and the Model Bundle. Three
    independent signals, because each one alone has a hole:

      * **Content digest** is the strongest and has no false positives, but needs the corpus on
        disk, and `/data/` is untracked.
      * **Path fragments** are drawn from the real filenames on disk — `oft_reddit_`,
        `rewind_no_ammeba`, `sofake_ood`, `ReWIND`, `commfor-lowq`, the two detector-weight
        prefixes — so a renamed copy in a different directory is still caught, and a clean
        checkout can still run this half.
      * **Extensions** catch a corpus artifact this script has never seen. `.png` and `.jpg` are
        deliberately *not* on that list: an application legitimately ships images, so banning
        the extension would report findings in correct code while still missing a renamed file.
        `.parquet`, `.npy`, `.pth`, `.zip`, and `.csv` are on it, and every corpus index table
        and detector checkpoint on disk uses one of them.
    """
    matched_files = 0
    for bundle_name, entries in inventories.items():
        for entry in entries:
            candidates = index.get(entry["byteCount"], [])
            for candidate in candidates:
                matched_files += 1
                if digest_of(candidate) == entry["sha256"]:
                    report.fail(
                        CORPUS_ARTIFACT,
                        f"{composition_name}: {bundle_name}/{entry['path']} is byte-identical "
                        f"to evaluation-corpus content at "
                        f"{candidate.relative_to(repository)} (Requirement 14.6)",
                    )
            name = pathlib.PurePath(entry["path"]).name
            for fragment in CORPUS_PATH_FRAGMENTS:
                if fragment.lower() in entry["path"].lower():
                    report.fail(
                        CORPUS_ARTIFACT,
                        f"{composition_name}: {bundle_name}/{entry['path']} names the corpus "
                        f"fragment {fragment!r} (Requirement 14.6)",
                    )
            for extension in CORPUS_EXTENSIONS:
                if name.lower().endswith(extension):
                    report.fail(
                        CORPUS_ARTIFACT,
                        f"{composition_name}: {bundle_name}/{entry['path']} carries the "
                        f"non-distributable extension {extension} (Requirement 14.6)",
                    )
    report.facts[f"{composition_name}.corpusDigestComparisons"] = matched_files
    report.facts["corpusFilesIndexed"] = corpus_file_count
    report.say(
        f"  {composition_name}: {sum(len(v) for v in inventories.values())} bundled file(s) "
        f"checked against {corpus_file_count} corpus file(s) by size then digest, plus "
        f"{len(CORPUS_PATH_FRAGMENTS)} name fragment(s) and {len(CORPUS_EXTENSIONS)} extension(s)"
    )

    # The Model Bundle half of Requirement 14.6 has no artifact to verify, which is a gap rather
    # than a pass. 12.5 measured the same absence from the other direction and recorded
    # `bundled-model-absent`; this states what it means for *this* requirement.
    report.owe("produced-initial-model-bundle-artifact-tree")
    report.observe(
        "model-bundle-corpus-exclusion-unverifiable",
        composition=composition_name,
        requirements=["14.6", "10.1"],
        note=(
            "Requirement 14.6 verifies corpus absence from the application *and the Model "
            "Bundle*. The application half is measured above. No produced Model Bundle "
            "artifact tree exists — task 14.5 built the creation and verification tooling and "
            "no bundle is embedded in a build, which 12.5 recorded as `bundled-model-absent` — "
            "so the Model Bundle half is unverifiable from these bytes and is owed rather than "
            "passed."
        ),
    )


# MARK: - Layer 6: privacy manifests

def check_privacy_manifests(
    composition_name: str, app: pathlib.Path, report: Report
) -> list[dict]:
    """Audit every embedded privacy manifest, and the absence of a first-party one.

    Requirement 9.13 forbids analytics and advertising identifiers and Requirement 9.18 makes
    the Release Process verify their absence together with analytics collection, custom
    diagnostic transmission, and third-party crash reporting. A `PrivacyInfo.xcprivacy` is the
    one place iOS declares all five of those things, and no existing check reads one: 12.3
    scans `Info.plist` and entitlements keys, and 12.5 scans the same two files for export and
    update keys.

    Two different results come out of this, and only one is a finding:

      * every embedded manifest must declare `NSPrivacyTracking` false, no tracking domain, and
        no forbidden collected-data type or accessed-API category. A `true`, a domain, or a
        category is a `prohibited-capability` finding; and
      * neither target ships a first-party manifest at all. That is a release-artifact gap, so
        it is owed rather than reported as a defect — this script does not author a release
        artifact — and the privacy-audit gate fails on it either way.
    """
    manifests: list[dict] = []
    for path in sorted(app.rglob("*.xcprivacy")):
        relative = str(path.relative_to(app))
        try:
            with path.open("rb") as handle:
                contents = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException) as error:
            report.fail(
                PROHIBITED_CAPABILITY,
                f"{composition_name}: {relative} is not a readable plist: {error}",
            )
            continue
        tracking = contents.get("NSPrivacyTracking", False)
        domains = contents.get("NSPrivacyTrackingDomains", []) or []
        collected = [
            entry.get("NSPrivacyCollectedDataType", "")
            for entry in contents.get("NSPrivacyCollectedDataTypes", []) or []
        ]
        accessed = [
            entry.get("NSPrivacyAccessedAPIType", "")
            for entry in contents.get("NSPrivacyAccessedAPITypes", []) or []
        ]
        report.require(
            tracking is False,
            PROHIBITED_CAPABILITY,
            f"{composition_name}: {relative} declares NSPrivacyTracking {tracking!r} "
            "(Requirements 9.10, 9.13, 9.18)",
        )
        report.require(
            not domains,
            PROHIBITED_CAPABILITY,
            f"{composition_name}: {relative} declares tracking domains {domains} "
            "(Requirements 9.2, 9.13, 9.18)",
        )
        forbidden_data = sorted(set(collected) & set(FORBIDDEN_PRIVACY_DATA_TYPES))
        report.require(
            not forbidden_data,
            PROHIBITED_CAPABILITY,
            f"{composition_name}: {relative} declares collected data types {forbidden_data} "
            "(Requirements 9.1, 9.2, 9.10, 9.11, 9.12, 9.18)",
        )
        forbidden_api = sorted(set(accessed) & set(FORBIDDEN_PRIVACY_API_TYPES))
        report.require(
            not forbidden_api,
            PROHIBITED_CAPABILITY,
            f"{composition_name}: {relative} declares accessed API categories "
            f"{forbidden_api} (Requirements 9.14, 9.15, 9.17)",
        )
        manifests.append(
            {
                "path": relative,
                "tracking": bool(tracking),
                "trackingDomains": list(domains),
                "collectedDataTypes": sorted(t for t in collected if t),
                "accessedAPITypes": sorted(t for t in accessed if t),
            }
        )

    # A first-party manifest is one either shipping target declares about itself, which means it
    # sits at the root of the `.app` or at the root of the `.appex`. Anything nested inside a
    # `<package>_<module>.bundle` is a dependency's declaration about itself.
    #
    # Spelled positionally rather than by excluding known package-name prefixes, which is how the
    # first version of this got it wrong: excluding paths containing a slash after stripping
    # `PlugIns/` classified the Share Extension's own manifest as third-party, so a first-party
    # manifest that did exist in the extension would not have counted.
    first_party = [
        entry
        for entry in manifests
        if pathlib.PurePath(entry["path"]).parent in (pathlib.PurePath("."),)
        or pathlib.PurePath(entry["path"]).parent.suffix == ".appex"
    ]
    if not first_party:
        report.owe("first-party-privacy-manifest")
        report.observe(
            "first-party-privacy-manifest-absent",
            composition=composition_name,
            requirements=["9.13", "9.18"],
            embeddedThirdPartyManifests=[entry["path"] for entry in manifests],
            note=(
                "Neither the application nor the Share Extension ships a "
                "PrivacyInfo.xcprivacy, so the absence Requirement 9.18 makes the Release "
                "Process verify is established here only by inspecting bytes and sources, not "
                "by a declaration the platform itself carries. A privacy manifest is a release "
                "artifact and is owed rather than authored by this audit. The "
                f"{len(manifests)} embedded third-party manifest(s) were audited and each "
                "declares no tracking, no tracking domain, and no collected data type."
            ),
        )
    report.facts[f"{composition_name}.privacyManifests"] = manifests
    report.facts[f"{composition_name}.firstPartyPrivacyManifests"] = [
        entry["path"] for entry in first_party
    ]
    report.say(
        f"  {composition_name}: {len(manifests)} embedded privacy manifest(s) audited, "
        f"{len(first_party)} first-party"
    )
    return manifests


# MARK: - Layer 7: the Software Bill of Materials

# CycloneDX 1.6 JSON, and the reason for that choice rather than SPDX.
#
#   * `components[].hashes` is a first-class field with an `alg`/`content` pair, so an
#     unapproved *binary digest* — one of the five failing input classes — is a native SBOM
#     value rather than a note. SPDX 2.3 expresses the same thing through
#     `packages[].checksums`, which works, but the surrounding document is tag-value-shaped
#     even in its JSON form and would need more translation to reach a typed Swift value.
#   * `components[].properties` is an open namespaced key-value list, which is where the
#     *resolved git revision* goes. That value is what actually binds a pin to fixed bytes, and
#     neither format has a dedicated field for it; CycloneDX at least has a sanctioned place to
#     put it, whereas SPDX would need an `ExternalRef` or a free-text comment.
#   * `dependencies[]` is an explicit edge list, so the pixel-only and provenance closures are
#     two different graphs in two documents rather than one document with a conditional note.
#   * It is JSON-only with a stable schema, so `SoftwareBillOfMaterials` in
#     `DefAIkeReleaseValidation` decodes it directly. Task 14.8 needs typed evidence, and a
#     format that survives `Codable` without a parser is worth more here than one with broader
#     legal tooling — this document is a release-record input, not a licence filing.
#
# What the document deliberately does not contain: a licence *conclusion*. `licenses` is emitted
# only where a licence file was observed in the resolved checkout, as `name` plus the observed
# file's digest, never as an SPDX `id` this script decided on. Requirement 14.5's notices are
# approved documents and the design says the project expresses no legal conclusion.
SBOM_SPEC_VERSION = "1.6"
SBOM_FORMAT = "CycloneDX"


def package_url(package: ApprovedPackage) -> str:
    """A `pkg:swift/...` Package URL, spelled from the resolved location and version."""
    return f"pkg:swift/{package.identity}@{package.version}"


def build_sbom(
    composition_name: str,
    build_root: pathlib.Path,
    shipped: set[str],
    inventories: dict[str, list[dict]],
    slices: list[dict],
    weight: dict,
    report: Report,
) -> dict:
    """Assemble one composition's CycloneDX 1.6 document from measured facts only."""
    composition = {c.name: c for c in COMPOSITIONS}[composition_name]
    components: list[dict] = []
    dependency_edges: list[dict] = []
    root_reference = f"dev.defaike.composition.{composition_name}"

    for identity in sorted(APPROVED_BY_IDENTITY):
        package = APPROVED_BY_IDENTITY[identity]
        licences = observed_licence_files(build_root, package)
        component: dict = {
            "type": "library",
            "bom-ref": package_url(package),
            "name": identity,
            "version": package.version,
            "purl": package_url(package),
            "scope": "required" if identity in shipped else "excluded",
            "properties": [
                {"name": "dev.defaike.resolvedRevision", "value": package.revision},
                {
                    "name": "dev.defaike.shipsInThisComposition",
                    "value": "true" if identity in shipped else "false",
                },
                {"name": "dev.defaike.approvalRationale", "value": package.why},
            ],
        }
        if licences:
            component["licenses"] = [
                {
                    "license": {
                        "name": f"observed licence file {entry['file']}",
                        # A reference to fixed bytes, not a conclusion about their meaning.
                        "url": f"sha256:{entry['sha256']}",
                    }
                }
                for entry in licences
            ]
        components.append(component)
        if identity in shipped:
            dependency_edges.append(
                {"ref": root_reference, "dependsOn": [package_url(package)]}
            )

    if slices:
        components.append(
            {
                "type": "library",
                "bom-ref": "dev.defaike.binary.C2PAC",
                "name": VENDORED_BINARY_ARTIFACT["name"],
                "version": APPROVED_BY_IDENTITY["c2pa-swift"].version,
                "mime-type": "application/octet-stream",
                "hashes": [
                    {"alg": "SHA-256", "content": entry["sha256"]}
                    for entry in slices
                ],
                "externalReferences": [
                    {
                        "type": "distribution",
                        "url": VENDORED_BINARY_ARTIFACT["declaredURL"],
                        "hashes": [
                            {
                                "alg": "SHA-256",
                                "content": VENDORED_BINARY_ARTIFACT["declaredChecksum"],
                            }
                        ],
                    }
                ],
                "properties": [
                    {"name": "dev.defaike.binarySlice", "value": entry["slice"]}
                    for entry in slices
                ]
                + [
                    {
                        "name": "dev.defaike.digestApprovalStatus",
                        "value": VENDORED_BINARY_ARTIFACT["approvalStatus"],
                    }
                ],
            }
        )

    modules = sorted(
        stem
        for stem in report.facts.get(f"{composition_name}.wholeModuleObjects", [])
        if stem.startswith("DefAIke")
    )
    for module in modules:
        components.append(
            {
                "type": "library",
                "bom-ref": f"dev.defaike.module.{module}",
                "name": module,
                "version": "0.0.0",
                "scope": "required",
                "properties": [
                    {"name": "dev.defaike.origin", "value": "first-party"},
                    {
                        "name": "dev.defaike.note",
                        "value": (
                            "No application build identity is recorded in Info.plist, so no "
                            "release version is available for a first-party module and 0.0.0 "
                            "is the observed value rather than an approved one."
                        ),
                    },
                ],
            }
        )
    dependency_edges.append(
        {
            "ref": root_reference,
            "dependsOn": [f"dev.defaike.module.{module}" for module in modules],
        }
    )

    for bundle_name, entries in sorted(inventories.items()):
        for entry in entries:
            components.append(
                {
                    "type": "file",
                    "bom-ref": f"dev.defaike.file.{bundle_name}/{entry['path']}",
                    "name": f"{bundle_name}/{entry['path']}",
                    # `version` is deliberately omitted rather than set to an empty string. A
                    # built file has no version, and CycloneDX 1.6 makes the field optional; an
                    # empty value would be a claim that it has one and that the value is blank.
                    "hashes": [{"alg": "SHA-256", "content": entry["sha256"]}],
                    "properties": [
                        {"name": "dev.defaike.byteCount", "value": str(entry["byteCount"])}
                    ],
                }
            )

    model_component: dict = {
        "type": "machine-learning-model",
        "bom-ref": "dev.defaike.model.lowq-checkpoint",
        "name": REQUIRED_CHECKPOINT,
        "version": "2026-08",
        "hashes": [{"alg": "SHA-256", "content": REQUIRED_WEIGHT_DIGEST}],
        "properties": [
            {
                "name": "dev.defaike.upstreamAttribution",
                "value": f"derived from {CHECKPOINT_UPSTREAM} (MIT)",
            },
            {
                "name": "dev.defaike.presentInArchive",
                # Requirement 10.1's positive claim, stated as what the bytes show.
                "value": "false",
            },
            {
                # Approved, and by a stronger thing than a baseline measurement: Requirement 10.4
                # fixes this digest in the requirements document, and the check above cross-checks
                # it against `RequiredPixelModel.weightDigestHexadecimal` and against the compiled
                # blob when one is present. That is what distinguishes it from the C2PAC slices,
                # whose digests are only ever "the bytes previously measured".
                "name": "dev.defaike.digestApprovalStatus",
                "value": "release-approved",
            },
            {
                "name": "dev.defaike.digestSource",
                "value": (
                    "Requirement 10.4, cross-checked against "
                    "RequiredPixelModel.weightDigestHexadecimal"
                    + (
                        " and against the compiled weight blob in the working tree"
                        if weight.get("measuredWeightDigest")
                        else "; no compiled weight blob was present in this working tree"
                    )
                ),
            },
        ],
    }
    components.append(model_component)

    return {
        "bomFormat": SBOM_FORMAT,
        "specVersion": SBOM_SPEC_VERSION,
        "version": 1,
        "metadata": {
            # A fixed timestamp would be reproducible but false; a real one is a fact about the
            # run. The document's identity is its content, not its timestamp, and every value
            # that matters for reproducibility is a digest.
            "timestamp": datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
            "tools": {
                "components": [
                    {
                        "type": "application",
                        "name": "audit-release-archives.py",
                        "version": "14.6",
                    }
                ]
            },
            "component": {
                "type": "application",
                "bom-ref": root_reference,
                "name": "DefAIke",
                "version": "0.0.0",
                "properties": [
                    {"name": "dev.defaike.composition", "value": composition_name},
                    {
                        "name": "dev.defaike.bundleIdentifier",
                        "value": composition.bundle_identifier,
                    },
                    {
                        "name": "dev.defaike.buildConfiguration",
                        "value": "Debug-iphonesimulator",
                    },
                    {
                        "name": "dev.defaike.versionCaveat",
                        "value": (
                            "No release build identity exists in either target's Info.plist, "
                            "so 0.0.0 is observed rather than approved and this document "
                            "cannot be bound to a release version."
                        ),
                    },
                ],
            },
        },
        "components": components,
        # One entry per `ref`, with its edges merged. CycloneDX's dependency graph is keyed by
        # reference, so emitting the same `ref` several times would be two statements about one
        # node and a consumer would be entitled to keep either.
        "dependencies": [
            {"ref": reference, "dependsOn": sorted(targets)}
            for reference, targets in sorted(merged_edges(dependency_edges).items())
        ],
    }


def merged_edges(edges: list[dict]) -> dict[str, set[str]]:
    merged: dict[str, set[str]] = {}
    for edge in edges:
        merged.setdefault(edge["ref"], set()).update(edge["dependsOn"])
    return merged


# MARK: - Layer 8: the release-record input

def release_record_input(report: Report, archives_inspected: bool) -> dict:
    """Derive task 14.8's typed input from this run's findings, not from a second hand pass.

    One structure, and every field in it is derived:

      * `gates` carries one entry per `ReleaseGate` this task produces evidence for, with a
        `GateOutcome` of `passed`, `failed`, or `not-executed`. There is no fourth value and no
        warning level: Requirement 14.6 makes each of the five failing input classes a failing
        release-record input, and `GateOutcome.isPassing` in `DefAIkeDomain` is true only for
        `passed`.
      * A gate is `failed` when any finding of a class that maps to it exists, or when any
        release-controlled input it depends on is owed. Missing is never a pass, which is why
        `not-executed` is reserved for a run that did not inspect archives at all — and
        `not-executed` does not satisfy a gate either.
      * `unprovisionedInputs` are the raw values of `UnprovisionedArchiveAuditInput`, so the
        typed layer can distinguish "the build is wrong" from "a release artifact does not
        exist" without parsing prose.

    Deliberately absent: any signature, any approval, any eligibility conclusion, and any
    device or capability result. This is one input to a record 14.8 assembles and signs.
    """
    by_class: dict[str, list[str]] = {name: [] for name in FAILING_INPUT_CLASSES}
    for finding in report.findings:
        by_class[finding["class"]].append(finding["message"])

    gates: list[dict] = []
    for gate in ALL_GATES:
        classes = sorted(
            name for name, mapped in GATE_FOR_CLASS.items() if mapped == gate
        )
        failures = [message for name in classes for message in by_class[name]]
        owed = [
            identifier
            for identifier in sorted(report.unprovisioned)
            if identifier in OWED_INPUTS_FOR_GATE[gate]
        ]
        if not archives_inspected:
            outcome = "not-executed"
        elif failures or owed:
            outcome = "failed"
        else:
            outcome = "passed"
        gates.append(
            {
                "gate": gate,
                "outcome": outcome,
                "failingInputClasses": classes,
                "findings": failures,
                "unprovisionedInputs": owed,
            }
        )

    return {
        "schemaVersion": 1,
        "producedBy": "ios/Scripts/audit-release-archives.py",
        "task": "14.6",
        "archivesInspected": archives_inspected,
        "gates": gates,
        "findingsByClass": {name: sorted(messages) for name, messages in by_class.items()},
        "unprovisionedInputs": sorted(report.unprovisioned),
        "facts": report.facts,
        "observations": report.observations,
    }


# MARK: - Drivers

def run_static_checks(root: pathlib.Path, report: Report) -> None:
    report.say("Dependency identity, version and revision")
    check_dependency_identities(root, report)
    report.say("Required pixel-model weight digest")
    check_model_weight_digest(root, report)
    # Two inputs are owed by every run, regardless of what it measures, and they are owed here
    # rather than inside a check so a run that skipped archives still reports them. Requirement
    # 14.1 wants each gate's evidence to name a source artifact identifier and version, and this
    # audit's dependency allowlist is a table in a script rather than a signed artifact.
    report.owe("approved-external-dependency-allowlist-artifact")
    report.owe("distribution-archive")
    report.observe(
        "audited-artifacts-are-not-distribution-artifacts",
        requirements=["14.1", "14.5", "14.6"],
        note=(
            "Every archive claim this audit makes is about a Debug simulator build produced "
            "with CODE_SIGNING_ALLOWED=NO. A distribution archive differs in the ways an audit "
            "most wants to read: it is signed, thinned to device architectures, and carries its "
            "Swift code in the main executable rather than in a .debug.dylib. So no code "
            "signature is verifiable here, and no archive claim can be bound to a release "
            "version, because both shipping targets record build identity 0/0.0.0."
        ),
    )


def run_archive_checks(
    builds: dict[str, pathlib.Path],
    report: Report,
    sbom_directory: pathlib.Path | None,
) -> dict[str, dict]:
    """Inspect both archives. Both are required, because several checks compare them."""
    index, corpus_count = corpus_size_index(REPOSITORY, report)
    sboms: dict[str, dict] = {}

    for composition in COMPOSITIONS:
        build_root = builds[composition.name]
        products = build_root / "Build" / "Products" / "Debug-iphonesimulator"
        app = products / "DefAIke.app"
        report.say(f"{composition.name}")
        if not app.is_dir():
            report.fail(
                PROHIBITED_CAPABILITY,
                f"{composition.name}: {app} does not exist; build the scheme with its own "
                "-derivedDataPath first",
            )
            continue

        # Self-attribution, the same way 12.3 and 12.5 do it: the artifact says which
        # composition it is, and the caller's flag is cross-checked against that rather than
        # trusted. Both schemes build `DefAIke.app` to the same path under a shared
        # PRODUCT_NAME, so a swapped pair of build roots must be a finding.
        try:
            with (app / "Info.plist").open("rb") as handle:
                identifier = plistlib.load(handle).get("CFBundleIdentifier", "")
        except (OSError, plistlib.InvalidFileException) as error:
            report.fail(
                PROHIBITED_CAPABILITY,
                f"{composition.name}: {app}/Info.plist is not a readable plist: {error}",
            )
            continue
        if identifier != composition.bundle_identifier:
            report.fail(
                PROHIBITED_CAPABILITY,
                f"the archive at {products} identifies itself as {identifier!r} but was "
                f"supplied as the {composition.name} archive, which is "
                f"{composition.bundle_identifier!r}; the two build roots were swapped or share "
                "one derived-data path",
            )
            continue

        shipped = check_module_attribution(composition.name, build_root, report)
        slices = check_binary_artifact(build_root, report) if composition.links_validator else []

        inventories = {
            bundle.name: inventory_bundle(bundle)
            for bundle in bundles_in(app)
        }
        report.facts[f"{composition.name}.bundleFileCounts"] = {
            name: len(entries) for name, entries in sorted(inventories.items())
        }
        report.say(
            "  release artifact manifest: "
            + json.dumps(
                {name: len(entries) for name, entries in sorted(inventories.items())},
                sort_keys=True,
            )
        )

        check_required_notices(
            composition.name, build_root, shipped, inventories, report
        )
        check_corpus_exclusion(
            composition.name, inventories, index, corpus_count, REPOSITORY, report
        )
        check_privacy_manifests(composition.name, app, report)

        sboms[composition.name] = build_sbom(
            composition.name,
            build_root,
            shipped,
            inventories,
            slices,
            report.facts.get("modelWeightDigest", {}),
            report,
        )

    if sbom_directory is not None:
        sbom_directory.mkdir(parents=True, exist_ok=True)
        for name, document in sorted(sboms.items()):
            path = sbom_directory / f"sbom-{name}.cdx.json"
            path.write_text(json.dumps(document, indent=2, sort_keys=True), encoding="utf-8")
            report.say(
                f"  wrote {path} ({len(document['components'])} components, "
                f"{SBOM_FORMAT} {SBOM_SPEC_VERSION})"
            )
    return sboms


# MARK: - Non-vacuity self-tests

# Each entry plants one real violation in a copy of the repository and names the substring the
# check that must fire will produce. A check nobody has seen fail is a check nobody has seen
# work: 12.2 measured a scanner whose patterns never matched, and 12.3 shipped a `\b`-anchored
# symbol scan that was silently vacuous for the same reason.
SELF_TESTS: list[tuple[str, str]] = [
    ("unapproved-resolved-package", "has no approved entry"),
    ("drifted-version", "resolves to version"),
    ("drifted-revision", "resolves to revision"),
    ("removed-approved-package", "resolve to nothing"),
    ("duplicate-pin", "more than once"),
    ("weight-digest-drift", "does not carry the required weight digest"),
    ("checkpoint-name-drift", "does not name the required checkpoint"),
]


def plant(name: str, root: pathlib.Path) -> None:
    """Introduce one real violation into a copied tree."""
    resolved = root / "DefAIkePackage" / "Package.resolved"
    model = root / MODEL_IDENTITY_RELATIVE

    def rewrite_resolved(mutate) -> None:
        document = json.loads(resolved.read_text(encoding="utf-8"))
        mutate(document)
        resolved.write_text(json.dumps(document, indent=2), encoding="utf-8")

    def rewrite(path: pathlib.Path, old: str, new: str) -> None:
        text = path.read_text(encoding="utf-8")
        assert old in text, f"self-test {name}: {path.name} does not contain {old!r}"
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    if name == "unapproved-resolved-package":
        rewrite_resolved(
            lambda document: document["pins"].append(
                {
                    "identity": "analytics-sdk",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/example/analytics-sdk.git",
                    "state": {"revision": "0" * 40, "version": "1.0.0"},
                }
            )
        )
    elif name == "drifted-version":
        def bump(document: dict) -> None:
            for pin in document["pins"]:
                if pin["identity"] == "c2pa-swift":
                    pin["state"]["version"] = "0.0.13"
        rewrite_resolved(bump)
    elif name == "drifted-revision":
        def retag(document: dict) -> None:
            for pin in document["pins"]:
                if pin["identity"] == "swift-asn1":
                    pin["state"]["revision"] = "f" * 40
        rewrite_resolved(retag)
    elif name == "removed-approved-package":
        rewrite_resolved(
            lambda document: document.__setitem__(
                "pins",
                [pin for pin in document["pins"] if pin["identity"] != "swift-crypto"],
            )
        )
    elif name == "duplicate-pin":
        def duplicate(document: dict) -> None:
            first = dict(document["pins"][0])
            document["pins"].append(first)
        rewrite_resolved(duplicate)
    elif name == "weight-digest-drift":
        rewrite(model, REQUIRED_WEIGHT_DIGEST, "0" * 64)
    elif name == "checkpoint-name-drift":
        rewrite(model, REQUIRED_CHECKPOINT, "Example/some-other-checkpoint")
    else:  # pragma: no cover - the table and this function are edited together.
        raise AssertionError(f"unknown self-test {name}")


def self_test() -> int:
    """Prove every static check can fail, by planting one real violation at a time."""
    print("Non-vacuity self-test (static)")
    baseline = Report(quiet=True)
    run_static_checks(IOS, baseline)
    if baseline.findings:
        print("FAIL: the unmodified repository already has findings; self-test is meaningless")
        for message in baseline.messages():
            print("  " + message)
        return 1
    print(f"  baseline: {len(SELF_TESTS)} planted violations to check, 0 findings unmodified")

    failures = 0
    for name, expected in SELF_TESTS:
        with tempfile.TemporaryDirectory(prefix="t146-selftest-") as temporary:
            root = pathlib.Path(temporary) / "ios"
            shutil.copytree(
                IOS,
                root,
                ignore=shutil.ignore_patterns(
                    ".build", "DefAIke.xcodeproj", "DefAIke.xcworkspace", "*.xcuserdatad"
                ),
            )
            plant(name, root)
            report = Report(quiet=True)
            run_static_checks(root, report)
            matched = [message for message in report.messages() if expected in message]
            if matched:
                print(f"  PASS {name}: {matched[0][:112]}")
            else:
                failures += 1
                print(f"  FAIL {name}: no finding contained {expected!r}")
                for message in report.messages():
                    print(f"        got: {message[:112]}")
    print()
    if failures:
        print(f"self-test FAILED ({failures} of {len(SELF_TESTS)} checks did not fire)")
        return 1
    print(f"self-test PASS ({len(SELF_TESTS)} of {len(SELF_TESTS)} checks fire)")
    return 0


def staged_build_root(build_root: pathlib.Path, destination: pathlib.Path) -> pathlib.Path:
    """A writable copy of one build's products, sharing the rest of the build by reference.

    An archive check cannot be validated by planting a violation in a source tree: producing an
    archive that contained a corpus image would mean building a different project. So the probes
    below plant into a *copy of the built bundle* instead, which exercises the real inspection
    over real bytes plus one added file.

    The bundle is hardlinked rather than byte-copied, and `SourcePackages` — which holds the
    420 MB vendor artifact — is symlinked, so a probe costs milliseconds instead of a gigabyte.
    """
    products = destination / "Build" / "Products" / "Debug-iphonesimulator"
    products.mkdir(parents=True)
    source_products = build_root / "Build" / "Products" / "Debug-iphonesimulator"
    shutil.copytree(
        source_products / "DefAIke.app",
        products / "DefAIke.app",
        copy_function=lambda source, target: pathlib.Path(target).hardlink_to(source),
        symlinks=True,
    )
    for path in sorted(source_products.glob("*.o")):
        (products / path.name).hardlink_to(path)
    source_packages = build_root / "SourcePackages"
    if source_packages.is_dir():
        (destination / "SourcePackages").symlink_to(source_packages)
    return destination


def self_test_archives(builds: dict[str, pathlib.Path]) -> int:
    """Prove every archive check can fail, by planting real content into a staged bundle.

    Nine probes, and the two inverted ones matter as much as the seven that require a finding:
    a corpus scan that reported zero without ever having been shown to report one is worthless,
    and so is a notice check that can only ever fail.
    """
    print("Non-vacuity self-test (archives)")
    expectations: list[tuple[str, str, int]] = []
    corpus_index, corpus_count = corpus_size_index(REPOSITORY, Report(quiet=True))

    corpus_sample: pathlib.Path | None = None
    for size, paths in sorted(corpus_index.items()):
        if 1024 < size < 4 << 20:
            corpus_sample = paths[0]
            break

    with tempfile.TemporaryDirectory(prefix="t146-archive-probe-") as temporary:
        base = pathlib.Path(temporary)

        # 1-3. The three corpus signals, each planted separately so one cannot mask another.
        for label, filename, expected in [
            ("byte-identical corpus image", "planted-evidence.bin", "byte-identical to"),
            ("corpus name fragment", "oft_reddit_000000.bin", "names the corpus fragment"),
            ("non-distributable extension", "results.parquet", "non-distributable extension"),
        ]:
            if corpus_sample is None:
                expectations.append((f"corpus probe: {label}", "no corpus on disk", 0))
                continue
            staged = staged_build_root(
                builds[PIXEL_ONLY.name], base / f"corpus-{filename}"
            )
            app = staged / "Build" / "Products" / "Debug-iphonesimulator" / "DefAIke.app"
            shutil.copyfile(corpus_sample, app / filename)
            report = Report(quiet=True)
            inventories = {
                bundle.name: inventory_bundle(bundle) for bundle in bundles_in(app)
            }
            check_corpus_exclusion(
                PIXEL_ONLY.name, inventories, corpus_index, corpus_count, REPOSITORY, report
            )
            expectations.append(
                (
                    f"corpus probe: {label}",
                    expected,
                    len([m for m in report.messages() if expected in m]),
                )
            )

        # 4. The privacy-manifest audit, against a manifest that declares tracking.
        staged = staged_build_root(builds[PIXEL_ONLY.name], base / "privacy")
        app = staged / "Build" / "Products" / "Debug-iphonesimulator" / "DefAIke.app"
        (app / "PrivacyInfo.xcprivacy").write_bytes(
            plistlib.dumps(
                {
                    "NSPrivacyTracking": True,
                    "NSPrivacyTrackingDomains": ["analytics.example.com"],
                    "NSPrivacyCollectedDataTypes": [
                        {"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeDeviceID"}
                    ],
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType":
                                "NSPrivacyAccessedAPICategoryUserDefaults"
                        }
                    ],
                }
            )
        )
        report = Report(quiet=True)
        check_privacy_manifests(PIXEL_ONLY.name, app, report)
        for expected in [
            "declares NSPrivacyTracking True",
            "declares tracking domains",
            "declares collected data types",
            "declares accessed API categories",
        ]:
            expectations.append(
                (
                    f"privacy-manifest probe: {expected}",
                    expected,
                    len([m for m in report.messages() if expected in m]),
                )
            )

        # 4b. The first-party detection's *positive* direction. Every real run reports zero
        # first-party manifests, so without this probe the positional rule could be wrong in the
        # direction that never shows — and it was, once: an earlier version classified the Share
        # Extension's own manifest as third-party, which would have hidden a first-party manifest
        # that did exist.
        staged = staged_build_root(builds[PIXEL_ONLY.name], base / "first-party-privacy")
        app = staged / "Build" / "Products" / "Debug-iphonesimulator" / "DefAIke.app"
        clean_manifest = plistlib.dumps(
            {
                "NSPrivacyTracking": False,
                "NSPrivacyTrackingDomains": [],
                "NSPrivacyCollectedDataTypes": [],
                "NSPrivacyAccessedAPITypes": [],
            }
        )
        (app / "PrivacyInfo.xcprivacy").write_bytes(clean_manifest)
        for appex in sorted(app.rglob("*.appex")):
            (appex / "PrivacyInfo.xcprivacy").write_bytes(clean_manifest)
        report = Report(quiet=True)
        check_privacy_manifests(PIXEL_ONLY.name, app, report)
        found = report.facts.get(f"{PIXEL_ONLY.name}.firstPartyPrivacyManifests", [])
        expectations.append(
            (
                f"first-party privacy manifests in the app and the .appex are recognised {found}",
                "",
                1
                if len(found) == 2
                and not report.messages()
                and "first-party-privacy-manifest" not in report.unprovisioned
                else 0,
            )
        )

        # 5. Module attribution, against an object no resolved package defines.
        staged = staged_build_root(builds[PROVENANCE.name], base / "module")
        products = staged / "Build" / "Products" / "Debug-iphonesimulator"
        shutil.copyfile(products / "C2PA.o", products / "AnalyticsSDK.o")
        report = Report(quiet=True)
        check_module_attribution(PROVENANCE.name, staged, report)
        expectations.append(
            (
                "module attribution refuses an unattributable object",
                "could not be attributed to any resolved package",
                len(
                    [
                        m
                        for m in report.messages()
                        if "could not be attributed to any resolved package" in m
                    ]
                ),
            )
        )

        # 6. The notice check's *passing* direction. A check that can only fail is not a check,
        # and every real run of this one fails, so the probe stages the notices it asks for and
        # requires silence.
        staged = staged_build_root(builds[PROVENANCE.name], base / "notices")
        app = staged / "Build" / "Products" / "Debug-iphonesimulator" / "DefAIke.app"
        notices = app / "Notices"
        notices.mkdir()
        report = Report(quiet=True)
        shipped = check_module_attribution(PROVENANCE.name, staged, report)
        for subject in [CHECKPOINT_NOTICE_SUBJECT] + sorted(shipped):
            (notices / f"{subject}-LICENSE.txt").write_text(
                "staged by the non-vacuity probe; not an approved notice\n", encoding="utf-8"
            )
        inventories = {
            bundle.name: inventory_bundle(bundle) for bundle in bundles_in(app)
        }
        probe = Report(quiet=True)
        check_required_notices(PROVENANCE.name, staged, shipped, inventories, probe)
        gaps = [m for m in probe.messages() if m.startswith(NOTICE_GAP)]
        expectations.append(
            (
                f"notice check passes when all {len(shipped) + 1} owed notices are staged",
                "",
                0 if gaps else 1,
            )
        )

        # 7. The notice check's failing direction, over the real archive.
        report = Report(quiet=True)
        shipped = check_module_attribution(PROVENANCE.name, builds[PROVENANCE.name], report)
        real_app = (
            builds[PROVENANCE.name] / "Build" / "Products" / "Debug-iphonesimulator"
            / "DefAIke.app"
        )
        inventories = {
            bundle.name: inventory_bundle(bundle)
            for bundle in bundles_in(real_app)
        }
        probe = Report(quiet=True)
        check_required_notices(
            PROVENANCE.name, builds[PROVENANCE.name], shipped, inventories, probe
        )
        expectations.append(
            (
                "notice check reports every owed notice absent from the real archive",
                "no notice for",
                len([m for m in probe.messages() if "no notice for" in m]),
            )
        )

        # 8. The binary-digest comparison. A 420 MB slice cannot be usefully mutated in a probe,
        # so the baseline is redirected instead — the same substitution 12.5 uses for its symbol
        # vocabularies — and the check must refuse the real bytes.
        global VENDORED_BINARY_ARTIFACT  # noqa: PLW0603 - restored immediately
        saved = VENDORED_BINARY_ARTIFACT
        try:
            VENDORED_BINARY_ARTIFACT = dict(saved)
            VENDORED_BINARY_ARTIFACT["sliceDigests"] = {
                name: {"sha256": "0" * 64, "byteCount": 1}
                for name in saved["sliceDigests"]
            }
            VENDORED_BINARY_ARTIFACT["declaredChecksum"] = "1" * 64
            report = Report(quiet=True)
            check_binary_artifact(builds[PROVENANCE.name], report)
            for expected in ["digests to", "bytes, baseline", "declares checksum"]:
                expectations.append(
                    (
                        f"binary-digest probe: {expected}",
                        expected,
                        len([m for m in report.messages() if expected in m]),
                    )
                )
        finally:
            VENDORED_BINARY_ARTIFACT = saved

        # 9. Archive self-attribution: a swapped pair of build roots must be refused.
        report = Report(quiet=True)
        run_archive_checks(
            {
                PIXEL_ONLY.name: builds[PROVENANCE.name],
                PROVENANCE.name: builds[PIXEL_ONLY.name],
            },
            report,
            None,
        )
        expectations.append(
            (
                "swapped build roots are refused by self-attribution",
                "the two build roots were swapped",
                len([m for m in report.messages() if "the two build roots were swapped" in m]),
            )
        )

        # 10. The inventory itself. Every check above reads it, so an empty one would make all
        # of them vacuous at once.
        report = Report(quiet=True)
        real_app = (
            builds[PIXEL_ONLY.name] / "Build" / "Products" / "Debug-iphonesimulator"
            / "DefAIke.app"
        )
        bundle_list = bundles_in(real_app)
        counts = {
            bundle.name: len(inventory_bundle(bundle))
            for bundle in bundle_list
        }
        expectations.append(
            (
                f"release artifact manifest is non-empty for every bundle {counts}",
                "",
                1 if len(counts) >= 2 and all(counts.values()) else 0,
            )
        )

    failures = 0
    for description, expected, count in expectations:
        if count:
            print(f"  PASS {description}" + (f" ({count} finding(s))" if expected else ""))
        else:
            failures += 1
            print(f"  FAIL {description}: nothing matched {expected!r}")
    print()
    if failures:
        print(f"archive self-test FAILED ({failures} of {len(expectations)} probes silent)")
        return 1
    print(f"archive self-test PASS ({len(expectations)} of {len(expectations)} probes fire)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pixel-only-build",
        type=pathlib.Path,
        help="the -derivedDataPath root of a Debug DefAIkeApp-PixelOnly build",
    )
    parser.add_argument(
        "--provenance-build",
        type=pathlib.Path,
        help="the -derivedDataPath root of a Debug DefAIkeApp-PixelPlusProvenance build",
    )
    parser.add_argument(
        "--sbom-directory",
        type=pathlib.Path,
        help="write one CycloneDX 1.6 document per composition into this directory",
    )
    parser.add_argument(
        "--release-input",
        type=pathlib.Path,
        help="write task 14.8's typed release-record input to this file",
    )
    parser.add_argument("--json", type=pathlib.Path, help="write findings and facts to a file")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove every static check can fail, by planting one violation at a time",
    )
    parser.add_argument(
        "--self-test-archives",
        action="store_true",
        help="prove every archive check can fail, by planting real content into a staged bundle",
    )
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    builds: dict[str, pathlib.Path | None] = {
        PIXEL_ONLY.name: arguments.pixel_only_build,
        PROVENANCE.name: arguments.provenance_build,
    }
    complete = all(path is not None for path in builds.values())

    if arguments.self_test_archives:
        if not complete:
            print(
                "error: --self-test-archives needs both build roots",
                file=sys.stderr,
            )
            return 2
        return self_test_archives({name: path for name, path in builds.items() if path})

    report = Report()

    print("Delegated audits (tasks 12.2, 12.3, and 12.5)")
    delegate_existing_audits(builds, report)
    run_static_checks(IOS, report)

    if complete:
        run_archive_checks(
            {name: path for name, path in builds.items() if path},
            report,
            arguments.sbom_directory,
        )
    else:
        print("Built archives")
        print(
            "  skipped: pass --pixel-only-build and --provenance-build. Both are required "
            "together: the notice, corpus, and dependency checks are per composition, and the "
            "binary-digest check only applies to the archive that links the validator."
        )

    if report.observations:
        print()
        print("Observations (measured, not violations)")
        for observation in report.observations:
            if observation["kind"] == "delegated-offline-privacy-observation":
                continue
            print("  " + json.dumps(observation, sort_keys=True)[:1400])
        delegated = [
            o
            for o in report.observations
            if o["kind"] == "delegated-offline-privacy-observation"
        ]
        if delegated:
            print(
                f"  ... plus {len(delegated)} delegated observation(s) from 12.3 and 12.5, "
                "in --json and --release-input"
            )

    if report.unprovisioned:
        print()
        print("Release-controlled inputs this repository does not carry")
        for identifier in sorted(report.unprovisioned):
            print("  " + identifier)

    payload = release_record_input(report, archives_inspected=complete)
    if arguments.release_input:
        arguments.release_input.write_text(
            json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8"
        )
        print(f"\nwrote {arguments.release_input}")
    if arguments.json:
        arguments.json.write_text(
            json.dumps(
                {
                    "findings": report.findings,
                    "observations": report.observations,
                    "facts": report.facts,
                    "unprovisionedInputs": sorted(report.unprovisioned),
                },
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        print(f"wrote {arguments.json}")

    print()
    print("Release-record gate outcomes (task 14.8 input)")
    for gate in payload["gates"]:
        print(
            f"  {gate['gate']}: {gate['outcome']} "
            f"({len(gate['findings'])} finding(s), "
            f"{len(gate['unprovisionedInputs'])} owed input(s))"
        )

    print()
    if report.findings:
        print(f"FAIL ({len(report.findings)} finding(s))")
        for message in report.messages():
            print("  " + message)
        return 1
    if report.unprovisioned:
        print(
            f"FAIL (0 findings, {len(report.unprovisioned)} release-controlled input(s) owed; "
            "a missing input is never a pass)"
        )
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
