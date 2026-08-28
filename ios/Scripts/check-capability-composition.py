#!/usr/bin/env python3
"""Enforce capability-composition isolation and the absence of six dependency classes.

Task 12.3 has two halves, and they need different kinds of evidence.

**Half one — linkage and version-pin integrity.** The application archive must contain the
reviewed Content Credential validator and no other, and must require the exact approved adapter
version. Three independent layers carry that, and this script owns two of them:

  1. *Declared module closure.* ``ios/Scripts/check-module-boundaries.py`` owns this and is not
     duplicated here: it reads `swift package dump-package` and proves `DefAIkeAppKit` reaches
     `DefAIkeProvenanceC2PA` while `DefAIkeShareExtensionKit` does not.

     The negative case matters more than it used to. A pixel-only application archive used to
     supply it, and its deletion is why this script's remaining absence claims rest on the
     Share Extension and on ``--self-test-products`` rather than on a second app.
  2. *Version-pin coherence.* Four places name the reviewed validator release, and this script
     requires all four to agree: the `exact:` pin in `Package.swift`, the resolved pin in
     `Package.resolved`, `C2PALibraryReader.reviewedImplementationVersion`, and the
     provenance app composition's `linkedImplementationVersions` entry — which must be read from
     the linked module rather than written as a literal, so a build cannot claim a release it
     does not link.
  3. *Shipped bytes.* Inspection of the built product: which frameworks it embeds, which
     module symbols its Mach-O images contain, and — the point of the pin — whether the archive
     that is supposed to contain the validator does.

**Half two — an absence proof.** Six dependency classes must be absent from every production
graph: network model-update clients, analytics, advertising, account, custom diagnostic
collection, and third-party crash reporting. They already are, so the deliverable is evidence,
not a removal. Evidence comes from three angles: the declared external dependency set (a closed
allowlist of five packages, each justified), a comment-and-string-stripped scan of every
production source for those classes' API surfaces, and the linked-framework and undefined-symbol
sets of the built archives.

Usage:

    ios/Scripts/check-capability-composition.py                    # static checks only
    ios/Scripts/check-capability-composition.py --products DIR     # + one built archive
    ios/Scripts/check-capability-composition.py --products DIR --expect pixel-plus-provenance
    ios/Scripts/check-capability-composition.py --json report.json # machine-readable
    ios/Scripts/check-capability-composition.py --self-test        # non-vacuity validation

Attribution — why ``--products`` needs no scheme flag to be trustworthy. The path cannot say
which scheme produced a binary, and a caller-supplied flag would just be a claim. But
`Info.plist` carries `CFBundleIdentifier` into the built bundle, so **the archive attributes
itself**. This script reads that identifier and derives the composition from it; `--expect` is a
cross-check that fails when the caller and the artifact disagree, not the source of truth. It
retains value with one composition: an archive built from some other spec, or a stale bundle
left in a shared products directory, is refused rather than silently audited under this
composition's rules.

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    xcodebuild build -workspace ios/DefAIke.xcworkspace \\
        -scheme DefAIkeApp -configuration Debug \\
        -destination 'generic/platform=iOS Simulator' \\
        -derivedDataPath /tmp/defaike CODE_SIGNING_ALLOWED=NO
    ios/Scripts/check-capability-composition.py \\
        --products /tmp/defaike/Build/Products/Debug-iphonesimulator

Deliberately out of scope. This script does not run an offline session, inspect result
persistence or export controls, or audit an `.xcarchive` or SBOM: task 12.5 owns the offline and
privacy smoke tests and task 14.6 owns SBOM and archive audit tooling. `--json` exists so both
can consume these findings instead of re-deriving them. Nor does it check `canImport`
reachability: under Xcode every package module is written to one shared build-products directory
that each target's import search path includes, so a reachability probe resolves modules a target
does not link. Reachability is not linkage.
"""

from __future__ import annotations

import argparse
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

# `strip_swift` is reused rather than reimplemented. Task 12.2 measured what an unstripped scan
# costs: 16 false positives across eight extension files, 36 across an earlier repository-wide
# audit, and one build broken by a doc comment naming a type. A third stripper would be a third
# thing to keep correct.
_SPEC = importlib.util.spec_from_file_location(
    "check_share_extension_target", IOS / "Scripts" / "check-share-extension-target.py"
)
assert _SPEC is not None and _SPEC.loader is not None
_SHARE_EXTENSION_CHECK = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_SHARE_EXTENSION_CHECK)
strip_swift = _SHARE_EXTENSION_CHECK.strip_swift


def code_preserving_strings(source: str) -> str:
    """Blank every comment-only line, keeping code lines — string literals included — verbatim.

    The version-pin section has to read *values out of* string literals (`exact: "0.0.12"`,
    `reviewedImplementationVersion = "0.0.12"`), which ``strip_swift`` deliberately blanks. So it
    is used here as an oracle rather than as the output: a line whose stripped form is entirely
    whitespace was nothing but a comment, and is dropped; every other line is kept unchanged.

    That reuses the one stripper instead of adding a second parser, and it removes the false
    positives that actually occur. What it does not remove is a trailing comment on a line that
    also has code — `let x = 1  // exact: "9.9.9"` would survive. Accepted deliberately, because
    this function is only used to extract a declared version and a dependency URL from four known
    declarations, never to decide whether a forbidden API is used; the scanning paths use
    ``strip_swift`` directly and are unaffected.
    """
    stripped = strip_swift(source)
    kept: list[str] = []
    for original, blanked in zip(source.splitlines(), stripped.splitlines()):
        kept.append(original if blanked.strip() else "")
    return "\n".join(kept)


# MARK: - The two compositions

class Composition:
    """One capability composition, as the facts an audit needs to identify and check it."""

    def __init__(
        self,
        name: str,
        bundle_identifier: str,
        product: str,
        source_directory: str,
        links_validator: bool,
    ) -> None:
        self.name = name
        self.bundle_identifier = bundle_identifier
        self.product = product
        self.source_directory = source_directory
        self.links_validator = links_validator


# One composition, and the asymmetry that used to make its linkage measurable is gone.
#
# While a pixel-only application archive existed, this list held two entries and the check
# that mattered was the *difference* between them: one archive had to carry no C2PA payload
# and the other had to carry some, so a run measured both directions and neither claim could
# pass vacuously. The two were merged into one app, so the negative case now lives outside
# this table — in the Share Extension's `.appex`, which `check-share-extension-target.py`
# audits, and in the declared module closure `check-module-boundaries.py` reads. What is
# left here is the positive claim, and `--self-test` is what keeps it non-vacuous.
COMPOSITIONS = [
    Composition(
        name="pixel-plus-provenance",
        bundle_identifier="dev.defaike.app",
        product="DefAIkeAppKit",
        source_directory="Shared",
        links_validator=True,
    ),
]
BY_BUNDLE_ID = {composition.bundle_identifier: composition for composition in COMPOSITIONS}

# The conditional adapter module, and the vendor module it wraps. Every symbol, framework, and
# file name below is one of these two, spelled the way a linker or a bundle spells it.
ADAPTER_MODULE = "DefAIkeProvenanceC2PA"
VENDOR_PACKAGE = "c2pa-swift"
VENDOR_SYMBOL_PATTERN = re.compile(r"c2pa", re.IGNORECASE)
VENDOR_BUNDLE_PATTERNS = ["*C2PA*", "*c2pa*"]


# MARK: - The declared external dependency set

# Every external package either production graph may reach, and why. A closed allowlist rather
# than a denylist of known-bad vendor names: a denylist can only refuse the analytics SDKs
# somebody thought to list, while this refuses every package nobody approved, including one
# nobody has heard of yet. That is what makes it the load-bearing evidence for all six classes.
ALLOWED_EXTERNAL_PACKAGES = {
    "swift-property-based": "test-only property-based toolchain; linked into no shipping product",
    "c2pa-swift": "the reviewed Content Credential validator; the app composition only",
    "swift-crypto": "transitive dependency of c2pa-swift",
    "swift-certificates": "transitive dependency of c2pa-swift",
    "swift-asn1": "transitive dependency of c2pa-swift and swift-certificates",
}


# MARK: - The six forbidden dependency classes

class ForbiddenClass:
    """One class of dependency that must be absent from both production graphs."""

    def __init__(
        self,
        identifier: str,
        requirements: list[str],
        summary: str,
        imports: list[str],
        symbols: list[str],
        frameworks: list[str],
        info_keys: list[str],
        entitlements: list[str],
    ) -> None:
        self.identifier = identifier
        self.requirements = requirements
        self.summary = summary
        self.imports = imports
        self.symbols = symbols
        self.frameworks = frameworks
        self.info_keys = info_keys
        self.entitlements = entitlements


# Each class names *API surfaces*, not bare words. That distinction is measured, not stylistic:
# `DefAIkePresentation` legitimately contains the code identifiers `advertisingIdentifier` and
# `analyticsIdentifier` — they are cases of `PrivacyDisclosureClaim`, the enumeration that states
# these things are absent — so a bare-identifier pattern reports two findings in correct code
# even after comments and string literals are stripped. An import or a framework type name cannot
# be written for any reason other than using it.
FORBIDDEN_CLASSES = [
    ForbiddenClass(
        identifier="network-model-update",
        requirements=["10.19", "10.21", "9.2", "9.3"],
        summary=(
            "Remote Model Updates stay disabled and no network query, discovery, or download "
            "request for a model update is issued"
        ),
        imports=["Network", "CFNetwork", "SystemConfiguration", "WebKit", "BackgroundTasks"],
        symbols=[
            "URLSession",
            "NSURLSession",
            "URLRequest",
            "NSURLConnection",
            "NWConnection",
            "NWListener",
            "NWPathMonitor",
            "WKWebView",
            "CFReadStreamCreate",
            "getaddrinfo",
            "BGAppRefreshTask",
            "BGProcessingTask",
        ],
        frameworks=["Network", "CFNetwork", "WebKit", "SystemConfiguration", "BackgroundTasks"],
        info_keys=["BGTaskSchedulerPermittedIdentifiers", "NSAppTransportSecurity"],
        entitlements=["com.apple.developer.networking.multipath"],
    ),
    ForbiddenClass(
        identifier="analytics",
        requirements=["9.10", "9.13", "9.18"],
        summary="No analytics collection and no analytics identifier",
        imports=[
            "AppTrackingTransparency",
            "FirebaseAnalytics",
            "GoogleAnalytics",
            "Amplitude",
            "Mixpanel",
            "Segment",
            "PostHog",
            "TelemetryDeck",
            "CountlyiOS",
        ],
        symbols=[
            "ATTrackingManager",
            "ASIdentifierManager",
            "identifierForVendor",
            "FIRAnalytics",
            "MSACAnalytics",
        ],
        frameworks=["AppTrackingTransparency", "AdServices", "AdSupport"],
        info_keys=["NSUserTrackingUsageDescription"],
        entitlements=[],
    ),
    ForbiddenClass(
        identifier="advertising",
        requirements=["9.13", "1.8"],
        summary="No advertising identifier and no ad attribution or ad delivery surface",
        imports=["AdSupport", "AdServices", "GoogleMobileAds", "AppLovinSDK", "FBAudienceNetwork"],
        symbols=["SKAdNetwork", "SKAdImpression", "AAAttribution", "GADBannerView"],
        frameworks=["AdSupport", "AdServices", "GoogleMobileAds"],
        info_keys=[
            "SKAdNetworkItems",
            "NSAdvertisingAttributionReportEndpoint",
            "SKAdNetworkIdentifier",
        ],
        entitlements=[],
    ),
    ForbiddenClass(
        identifier="account",
        requirements=["1.8", "9.2"],
        summary="No account, sign-in, purchase, or cloud-sync surface",
        imports=[
            "AuthenticationServices",
            "StoreKit",
            "CloudKit",
            "GameKit",
            "AccountsUI",
            "Accounts",
            "FirebaseAuth",
        ],
        symbols=[
            "ASAuthorizationAppleIDProvider",
            "ASWebAuthenticationSession",
            "SKPaymentQueue",
            "CKContainer",
            "NSUbiquitousKeyValueStore",
            "ACAccountStore",
        ],
        frameworks=["AuthenticationServices", "StoreKit", "CloudKit", "GameKit", "Accounts"],
        info_keys=["NSUbiquitousContainers", "ITSAppUsesNonExemptEncryption_account"],
        entitlements=[
            "com.apple.developer.applesignin",
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.ubiquity-kvstore-identifier",
            "com.apple.developer.in-app-payments",
        ],
    ),
    ForbiddenClass(
        identifier="custom-diagnostic-collection",
        requirements=["9.11", "9.18"],
        summary="No custom diagnostic collection or transmission",
        imports=["MetricKit", "DataDogCore", "NewRelic", "Instabug"],
        symbols=[
            "MXMetricManager",
            "MXMetricPayload",
            "MXDiagnosticPayload",
            "OSSignposter",
            "kdebug_signpost",
        ],
        frameworks=["MetricKit"],
        info_keys=[],
        entitlements=[],
    ),
    ForbiddenClass(
        identifier="third-party-crash-reporting",
        requirements=["9.12", "9.18"],
        summary="No third-party crash-reporting service and no installed crash handler",
        imports=[
            "FirebaseCrashlytics",
            "Crashlytics",
            "Sentry",
            "Bugsnag",
            "AppCenterCrashes",
            "KSCrash",
            "PLCrashReporter",
            "Raygun",
            "Embrace",
        ],
        symbols=[
            "NSSetUncaughtExceptionHandler",
            "SentrySDK",
            "BugsnagClient",
            "FIRCrashlytics",
            "MSACCrashes",
            "PLCrashReporter",
            # `sigaction` is deliberately absent, and it was on this list until it was measured.
            # Both archives reference `_sigaction`, in the app and in the extension, and no
            # DefAIke object file claims it: it arrives with the Swift runtime, not with a
            # crash reporter. Listing it made every run emit two observations nobody can act on,
            # which is how an observations section stops being read.
            # `NSSetUncaughtExceptionHandler` above is the API that actually installs a handler,
            # and it is checked in the sources as well as in the archive.
        ],
        frameworks=["Sentry", "Bugsnag", "FirebaseCrashlytics", "CrashReporter"],
        info_keys=[],
        entitlements=[],
    ),
]

# Production source roots. A superset of both capability compositions' module closures, so
# absence measured over this set implies absence in each of them, and the closure itself stays
# `check-module-boundaries.py`'s to derive.
#
# The two nonshipping modules are excluded because they are nonshipping: no product contains
# either, which that script separately proves, so scanning them would measure code that cannot
# reach an archive.
NONSHIPPING_MODULES = {"DefAIkeReleaseValidation", "DefAIkeTestSupport"}


def production_source_roots(root: pathlib.Path) -> list[pathlib.Path]:
    package_sources = root / "DefAIkePackage" / "Sources"
    modules = sorted(
        path
        for path in package_sources.iterdir()
        if path.is_dir() and path.name not in NONSHIPPING_MODULES
    ) if package_sources.is_dir() else []
    return modules + [root / "DefAIkeApp", root / "DefAIkeShareExtension"]


# MARK: - Findings

class Report:
    """Collects findings and observations so one run reports every one of them.

    Also owns progress output, so the self-test can run every check silently over a planted tree
    without the checks themselves knowing anything about a self-test.
    """

    def __init__(self, quiet: bool = False) -> None:
        self.findings: list[str] = []
        self.observations: list[dict] = []
        self.facts: dict = {}
        self.quiet = quiet

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.findings.append(message)

    def fail(self, message: str) -> None:
        self.findings.append(message)

    def observe(self, kind: str, **fields: object) -> None:
        self.observations.append({"kind": kind, **fields})

    def say(self, message: str) -> None:
        if not self.quiet:
            print(message)


# MARK: - 1. Adapter version-pin coherence

def check_version_pin(root: pathlib.Path, report: Report) -> None:
    """Require the four places that name the reviewed validator release to agree."""
    package_swift = root / "DefAIkePackage" / "Package.swift"
    resolved_path = root / "DefAIkePackage" / "Package.resolved"
    reader = (
        root / "DefAIkePackage" / "Sources" / ADAPTER_MODULE / "C2PALibraryReader.swift"
    )
    module = (
        root / "DefAIkePackage" / "Sources" / ADAPTER_MODULE
        / f"{ADAPTER_MODULE}Module.swift"
    )

    versions: dict[str, str | None] = {}

    # 1. The `exact:` pin in the package manifest, read from code rather than a comment.
    manifest_source = code_preserving_strings(package_swift.read_text(encoding="utf-8"))
    pin = re.search(
        r'url:\s*"[^"]*' + re.escape(VENDOR_PACKAGE) + r'[^"]*"\s*,\s*exact:\s*"([^"]+)"',
        manifest_source,
    )
    if pin is None:
        # A non-`exact` requirement is itself the finding: a range would let a resolve pick a
        # release nobody reviewed.
        loose = re.search(
            r'url:\s*"[^"]*' + re.escape(VENDOR_PACKAGE) + r'[^"]*"\s*,\s*(\w+)',
            manifest_source,
        )
        report.fail(
            f"Package.swift does not exact-pin {VENDOR_PACKAGE}"
            + (f"; found requirement `{loose.group(1)}`" if loose else "")
        )
        versions["Package.swift exact: pin"] = None
    else:
        versions["Package.swift exact: pin"] = pin.group(1)

    # 2. What a resolve actually produced, plus the revision it is bound to.
    try:
        resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report.fail(f"Package.resolved is unreadable: {error}")
        resolved = {"pins": []}
    vendor_pins = [
        entry for entry in resolved.get("pins", [])
        if entry.get("identity") == VENDOR_PACKAGE
    ]
    if len(vendor_pins) != 1:
        report.fail(
            f"Package.resolved records {len(vendor_pins)} {VENDOR_PACKAGE} pins, expected 1"
        )
        versions["Package.resolved pin"] = None
    else:
        state = vendor_pins[0].get("state", {})
        versions["Package.resolved pin"] = state.get("version")
        report.require(
            bool(state.get("revision")),
            f"Package.resolved records no revision for {VENDOR_PACKAGE}; a version tag alone "
            "does not bind the pin to fixed bytes",
        )
        report.facts["resolvedValidatorRevision"] = state.get("revision")

    # 3. The constant the adapter is written against.
    reader_source = code_preserving_strings(reader.read_text(encoding="utf-8"))
    constant = re.search(
        r'reviewedImplementationVersion\s*=\s*"([^"]+)"', reader_source
    )
    if constant is None:
        report.fail(
            f"{reader.name} declares no reviewedImplementationVersion string literal in code"
        )
        versions["C2PALibraryReader.reviewedImplementationVersion"] = None
    else:
        versions["C2PALibraryReader.reviewedImplementationVersion"] = constant.group(1)

    # The module marker must forward that constant rather than restate it, so the two cannot
    # drift.
    module_source = code_preserving_strings(module.read_text(encoding="utf-8"))
    report.require(
        re.search(
            r"reviewedValidatorVersion\s*=\s*C2PALibraryReader\.reviewedImplementationVersion",
            module_source,
        )
        is not None,
        f"{module.name} must set reviewedValidatorVersion from "
        "C2PALibraryReader.reviewedImplementationVersion rather than restating a version",
    )

    distinct = {value for value in versions.values() if value is not None}
    report.require(
        len(distinct) == 1 and len(versions) == len(
            [value for value in versions.values() if value is not None]
        ),
        "the reviewed validator release is named inconsistently: "
        + json.dumps(versions, sort_keys=True),
    )
    if len(distinct) == 1:
        report.facts["reviewedValidatorVersion"] = distinct.pop()
    report.say(f"  reviewed validator release: {json.dumps(versions, sort_keys=True)}")

    # 4. The app compositions' attestation, which is the half that binds the *archive*.
    for composition in COMPOSITIONS:
        path = (
            root / "DefAIkeApp" / composition.source_directory
            / "CompiledCapabilityComposition.swift"
        )
        source = code_preserving_strings(path.read_text(encoding="utf-8"))
        attestation = re.search(
            r"linkedImplementationVersions\s*:\s*\[CapabilityID\s*:\s*String\]\s*=\s*(\[[^\]]*\])",
            source,
        )
        if attestation is None:
            report.fail(
                f"{composition.name}: {path.name} declares no linkedImplementationVersions"
            )
            continue
        body = attestation.group(1)
        names_capability = ".contentCredentialValidation" in body
        report.require(
            names_capability == composition.links_validator,
            f"{composition.name}: linkedImplementationVersions "
            f"{'must' if composition.links_validator else 'must not'} attest a "
            f"content-credential-validation version, found `{body.strip()}`",
        )
        if composition.links_validator:
            # The value must be read out of the linked module. A string literal here would be a
            # version claim any build could make, which is exactly what the pin exists to stop.
            report.require(
                f"{ADAPTER_MODULE}Module.reviewedValidatorVersion" in body,
                f"{composition.name}: the attested content-credential-validation version must "
                f"be {ADAPTER_MODULE}Module.reviewedValidatorVersion, so it resolves only in a "
                f"build that links the adapter, found `{body.strip()}`",
            )
            report.require(
                re.search(r'"\d+\.\d+\.\d+"', body) is None,
                f"{composition.name}: linkedImplementationVersions must not hard-code a version "
                f"literal, found `{body.strip()}`",
            )
        report.say(f"  {composition.name}: attests {body.strip()}")


# MARK: - 2. The declared external dependency set

def check_declared_dependencies(root: pathlib.Path, report: Report) -> None:
    """Require every external package to be one of the five on the allowlist."""
    package_swift = root / "DefAIkePackage" / "Package.swift"
    manifest_source = code_preserving_strings(package_swift.read_text(encoding="utf-8"))

    declared = set()
    for url in re.findall(r'\.package\(\s*url:\s*"([^"]+)"', manifest_source):
        identity = url.rsplit("/", 1)[-1].removesuffix(".git")
        declared.add(identity)
    unapproved = declared - set(ALLOWED_EXTERNAL_PACKAGES)
    report.require(
        not unapproved,
        f"Package.swift declares unapproved external packages {sorted(unapproved)}; every "
        "external dependency needs an approved entry, and an unlisted one is how an analytics, "
        "advertising, account, diagnostic, crash-reporting, or model-update client arrives",
    )

    resolved_path = root / "DefAIkePackage" / "Package.resolved"
    try:
        resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report.fail(f"Package.resolved is unreadable: {error}")
        return
    resolved_identities = {entry.get("identity") for entry in resolved.get("pins", [])}
    unapproved_resolved = resolved_identities - set(ALLOWED_EXTERNAL_PACKAGES)
    report.require(
        not unapproved_resolved,
        f"Package.resolved pins unapproved packages {sorted(unapproved_resolved)}; a transitive "
        "dependency is still a dependency and needs an approved entry",
    )
    # Every allowlist entry must actually be used. An entry nobody resolves is a stale approval,
    # and a stale approval is how a name gets reused later for something else.
    stale = set(ALLOWED_EXTERNAL_PACKAGES) - resolved_identities
    report.require(
        not stale,
        f"the external dependency allowlist has unused entries {sorted(stale)}; remove them "
        "rather than keeping an approval nothing resolves",
    )
    report.facts["externalPackages"] = sorted(resolved_identities)
    report.say(f"  declared {sorted(declared)}")
    report.say(f"  resolved {sorted(resolved_identities)}")


# MARK: - 3. Production sources

def check_production_sources(root: pathlib.Path, report: Report) -> None:
    """Scan every production source for the six classes' API surfaces, code only."""
    patterns: list[tuple[re.Pattern[str], str, str]] = []
    for forbidden in FORBIDDEN_CLASSES:
        for name in forbidden.imports:
            patterns.append(
                (
                    re.compile(rf"\bimport\s+{re.escape(name)}\b"),
                    forbidden.identifier,
                    f"imports {name}",
                )
            )
        for symbol in forbidden.symbols:
            patterns.append(
                (
                    re.compile(rf"\b{re.escape(symbol)}\b"),
                    forbidden.identifier,
                    f"names {symbol}",
                )
            )

    scanned = 0
    for source_root in production_source_roots(root):
        if not source_root.is_dir():
            report.fail(f"{source_root} does not exist")
            continue
        for path in sorted(source_root.rglob("*.swift")):
            scanned += 1
            stripped = strip_swift(path.read_text(encoding="utf-8"))
            for number, line in enumerate(stripped.splitlines(), start=1):
                for pattern, class_id, why in patterns:
                    if pattern.search(line):
                        relative = path.relative_to(root)
                        report.fail(
                            f"{class_id}: {relative}:{number} {why}: {line.strip()}"
                        )
    report.require(scanned > 0, "no production Swift sources were scanned")
    report.facts["productionSourcesScanned"] = scanned
    report.say(f"  scanned {scanned} production sources, comments and string literals stripped")


def check_bundle_declarations(root: pathlib.Path, report: Report) -> None:
    """Scan both targets' Info.plist and entitlements for the six classes' declared keys."""
    declaration_files = [
        root / "DefAIkeApp" / "Support" / "Info.plist",
        root / "DefAIkeApp" / "Support" / "DefAIkeApp.entitlements",
        root / "DefAIkeShareExtension" / "Support" / "Info.plist",
        root / "DefAIkeShareExtension" / "Support" / "DefAIkeShareExtension.entitlements",
    ]
    checked = 0
    for path in declaration_files:
        if not path.is_file():
            report.fail(f"{path} does not exist")
            continue
        try:
            with path.open("rb") as handle:
                contents = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException) as error:
            report.fail(f"{path.name} is not a readable plist: {error}")
            continue
        checked += 1
        keys = set(contents)
        for forbidden in FORBIDDEN_CLASSES:
            declared = keys & set(forbidden.info_keys + forbidden.entitlements)
            report.require(
                not declared,
                f"{forbidden.identifier}: {path.name} declares {sorted(declared)}",
            )
    report.facts["declarationFilesChecked"] = checked
    report.say(f"  checked {checked} Info.plist and entitlements files")


# MARK: - 4. The built archive

def run_tool(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"{command[1]} failed")
    return result.stdout


def mach_o_images(app: pathlib.Path) -> list[pathlib.Path]:
    """Every Mach-O image a bundle carries, including plug-ins and embedded frameworks.

    A Debug build puts the module's own code in `<Name>.debug.dylib` and leaves a thin
    `<Name>` shim, so inspecting only the main executable measures the shim. That is exactly the
    kind of miss this list exists to prevent, and it also means an archive inspection has to walk
    plug-ins and `Frameworks/` rather than the top level alone.
    """
    images: list[pathlib.Path] = []
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix == ".dylib":
            images.append(path)
            continue
        # A bundle's executable has no extension and matches its enclosing bundle's stem, or, for
        # a framework, sits directly inside it.
        parent = path.parent
        if path.suffix == "" and parent.suffix in {".app", ".appex", ".framework"}:
            if path.name == parent.stem or parent.suffix == ".framework":
                images.append(path)
    return images


def check_products(products: pathlib.Path, expected: str | None, report: Report) -> None:
    """Inspect one built archive, attributed to a composition by the artifact itself."""
    app = products / "DefAIke.app"
    if not app.is_dir():
        report.fail(
            f"{app} does not exist; build one scheme with its own -derivedDataPath first"
        )
        return

    info_path = app / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        report.fail(f"{info_path} is not a readable plist: {error}")
        return
    bundle_identifier = info.get("CFBundleIdentifier", "")
    composition = BY_BUNDLE_ID.get(bundle_identifier)
    if composition is None:
        report.fail(
            f"{app.name} carries CFBundleIdentifier {bundle_identifier!r}, which is neither "
            f"composition's identifier ({sorted(BY_BUNDLE_ID)}); the archive cannot be attributed"
        )
        return
    if expected is not None and expected != composition.name:
        report.fail(
            f"--expect {expected} disagrees with the archive, which identifies itself as "
            f"{composition.name} through CFBundleIdentifier {bundle_identifier}"
        )
        return
    report.facts["inspectedComposition"] = composition.name
    report.facts["inspectedBundleIdentifier"] = bundle_identifier
    report.say(f"  archive identifies itself as {composition.name} ({bundle_identifier})")
    report.say(
        "  note: the composition above comes from the built Info.plist, not from the path or\n"
        "        a flag, so it is a fact about the artifact rather than a caller's claim."
    )

    # 4a. Embedded vendor payload. The application archive must carry some, which is the
    # positive half of the linkage claim. It is written as a branch on `links_validator` rather
    # than as a bare assertion so `--self-test-products` can invert the expectation over the
    # real bytes and prove this inspection can see a validator at all.
    embedded = sorted(
        {
            str(path.relative_to(app))
            for pattern in VENDOR_BUNDLE_PATTERNS
            for path in app.glob(pattern)
        }
        | {
            str(path.relative_to(app))
            for pattern in VENDOR_BUNDLE_PATTERNS
            for path in (app / "Frameworks").glob(pattern)
            if (app / "Frameworks").is_dir()
        }
    )
    if composition.links_validator:
        report.require(
            bool(embedded),
            f"{composition.name} embeds no C2PA payload; the application archive must "
            "contain the reviewed validator, and an archive without it would "
            "make the linkage claim unmeasured",
        )
    else:
        report.require(
            not embedded,
            f"{composition.name} embeds C2PA payload {embedded}; this composition is held "
            "to containing no Content Credential validator",
        )
    report.say(f"  embedded C2PA payload: {embedded or 'none'}")
    report.facts["embeddedValidatorPayload"] = embedded

    # 4b. Per-image symbols and linked frameworks.
    images = mach_o_images(app)
    report.require(bool(images), f"{app.name} contains no inspectable Mach-O image")

    # Symbol attribution below distinguishes "DefAIke wrote this" from "a reviewed dependency
    # brought it", and it does that by reading the per-module object files a build products
    # directory carries. If those are absent, every symbol becomes unattributable and the
    # AI-Buster-owned check passes for the wrong reason. So their presence is required rather than
    # assumed: an inspection that cannot attribute must say so instead of reporting a pass.
    defaike_objects = sorted(path.stem for path in products.glob("DefAIke*.o"))
    report.require(
        bool(defaike_objects),
        f"{products} contains no DefAIke*.o object files, so a forbidden symbol could not be "
        "attributed to an DefAIke module or to a dependency. Point --products at a build "
        "products directory rather than at an extracted archive payload.",
    )
    report.facts["attributableModules"] = defaike_objects
    vendor_symbol_totals: dict[str, int] = {}
    image_facts: list[dict] = []

    for image in images:
        try:
            linked = run_tool(["xcrun", "otool", "-L", str(image)])
            defined = run_tool(["xcrun", "nm", str(image)])
            undefined = run_tool(["xcrun", "nm", "-u", str(image)])
        except RuntimeError as error:
            report.fail(f"{image.relative_to(app)}: inspection failed: {error}")
            continue

        relative = str(image.relative_to(app))
        vendor_symbols = len(VENDOR_SYMBOL_PATTERN.findall(defined))
        vendor_symbol_totals[relative] = vendor_symbols
        frameworks = sorted(set(re.findall(r"/([A-Za-z0-9_]+)\.framework/", linked)))

        # The adapter module and the vendor module, in the archive that must not have them.
        if not composition.links_validator:
            report.require(
                vendor_symbols == 0,
                f"{composition.name}: {relative} contains {vendor_symbols} C2PA symbols",
            )
            # Substring for the same reason: a mangled symbol spells the module as
            # `21DefAIkeProvenanceC2PA`, with the length prefix fused to the name.
            report.require(
                ADAPTER_MODULE not in defined and ADAPTER_MODULE not in undefined,
                f"{composition.name}: {relative} references {ADAPTER_MODULE}",
            )

        # The Share Extension's images, in the archive that *does* link the validator.
        #
        # This is the negative case, asserted in the same run as the positive one. It replaces
        # what a second application archive used to supply: with one app there is no other
        # archive to compare against, but the extension ships inside this one and the Extension
        # Execution Policy forbids it any provenance code (Requirement 2.6). So "the inspection
        # can tell a linked validator from an absent one" is measured here rather than argued.
        if composition.links_validator and relative.startswith("PlugIns/"):
            report.require(
                vendor_symbols == 0,
                f"{composition.name}: {relative} contains {vendor_symbols} C2PA symbols; the "
                "Share Extension must link no Content Credential validator",
            )
            report.require(
                ADAPTER_MODULE not in defined and ADAPTER_MODULE not in undefined,
                f"{composition.name}: {relative} references {ADAPTER_MODULE}; the Share "
                "Extension must link no Content Credential validator",
            )

        # The six classes, in both archives.
        for forbidden in FORBIDDEN_CLASSES:
            linked_forbidden = sorted(set(forbidden.frameworks) & set(frameworks))
            report.require(
                not linked_forbidden,
                f"{forbidden.identifier}: {relative} links {linked_forbidden}",
            )
            # Substring, not `\b...\b`. Measured: the reference a linked build actually carries
            # is `_$sSo12NSURLSessionC10FoundationE4data3for8delegate...` and
            # `_OBJC_CLASS_$_NSURLSession`. A mangled Swift symbol embeds the type name with no
            # word boundary on either side, so a `\b`-anchored pattern matches neither and the
            # whole symbol check silently measures nothing. The source scan keeps `\b`, because
            # there the input is real Swift text.
            named = sorted(
                symbol for symbol in forbidden.symbols if symbol in undefined
            )
            if not named:
                continue
            # A symbol referenced by DefAIke's own code is a violation. A symbol that arrives
            # inside a reviewed third-party dependency is a supply-chain fact the Provenance
            # Feasibility Gate has to weigh, and reporting it as a violation of this task's
            # "remove the dependency" clause would be wrong: nothing here added it and removing
            # it means removing the reviewed validator. So it is attributed, not conflated.
            owners = attribute_symbols(products, named)
            defaike_owned = {
                symbol: modules
                for symbol, modules in owners.items()
                if any(module.startswith("DefAIke") for module in modules)
            }
            report.require(
                not defaike_owned,
                f"{forbidden.identifier}: {relative} references {sorted(defaike_owned)} from "
                f"DefAIke modules {sorted({m for v in defaike_owned.values() for m in v})}",
            )
            report.observe(
                "third-party-symbol-reference",
                composition=composition.name,
                image=relative,
                forbiddenClass=forbidden.identifier,
                requirements=forbidden.requirements,
                symbols=named,
                attributedTo={symbol: sorted(owners[symbol]) for symbol in named},
            )

        image_facts.append(
            {
                "image": relative,
                "frameworks": frameworks,
                "c2paSymbols": vendor_symbols,
            }
        )
        report.say(f"  {relative}: {len(frameworks)} frameworks, {vendor_symbols} C2PA symbols")

    report.facts["images"] = image_facts
    report.facts["c2paSymbolsPerImage"] = vendor_symbol_totals


def attribute_symbols(
    products: pathlib.Path, symbols: list[str]
) -> dict[str, set[str]]:
    """Which compiled module objects reference each symbol.

    A linked image is one unit, so a symbol found in it cannot be blamed on a module. The
    per-module `.o` files a build products directory carries alongside the bundle can be, which
    is what separates "DefAIke wrote this" from "a reviewed dependency brought it".

    Returns an empty owner set for a symbol no object claims, which happens when the products
    directory has no `.o` files — a distributed archive, for instance. An unattributable symbol
    is deliberately not treated as DefAIke's: this function reports what it can establish.
    """
    owners: dict[str, set[str]] = {symbol: set() for symbol in symbols}
    objects = sorted(products.glob("*.o"))
    for path in objects:
        try:
            undefined = run_tool(["xcrun", "nm", "-u", str(path)])
        except RuntimeError:
            continue
        for symbol in symbols:
            # Substring, for the same mangled-name reason as the image scan.
            if symbol in undefined:
                owners[symbol].add(path.stem)
    return owners


# MARK: - Non-vacuity self-test

# Each entry plants one violation in a copy of the repository and names the check that must fire.
# A check nobody has seen fail is a check nobody has seen work: 12.2 measured a scanner that
# reported nothing because its own patterns never matched, and this is how that is ruled out here.
SELF_TESTS: list[tuple[str, str]] = [
    ("version-pin-drift", "reviewed validator release is named inconsistently"),
    ("version-pin-literal", "must not hard-code a version literal"),
    ("version-pin-not-from-module", "must be DefAIkeProvenanceC2PAModule"),
    ("app-attests-nothing", "must attest a content-credential-validation"),
    ("loose-dependency-requirement", "does not exact-pin c2pa-swift"),
    ("unapproved-package", "declares unapproved external packages"),
    ("unapproved-resolved-package", "pins unapproved packages"),
    ("analytics-import", "analytics: "),
    ("network-symbol", "network-model-update: "),
    ("crash-handler-symbol", "third-party-crash-reporting: "),
    ("account-entitlement", "account: "),
    ("advertising-info-key", "advertising: "),
]


def plant(name: str, root: pathlib.Path) -> None:
    """Introduce one real violation into a copied tree."""
    package_swift = root / "DefAIkePackage" / "Package.swift"
    resolved = root / "DefAIkePackage" / "Package.resolved"
    reader = root / "DefAIkePackage" / "Sources" / ADAPTER_MODULE / "C2PALibraryReader.swift"
    composition = root / "DefAIkeApp" / "Shared" / "CompiledCapabilityComposition.swift"
    domain = root / "DefAIkePackage" / "Sources" / "DefAIkeDomain"
    entitlements = root / "DefAIkeApp" / "Support" / "DefAIkeApp.entitlements"
    info = root / "DefAIkeApp" / "Support" / "Info.plist"

    def rewrite(path: pathlib.Path, old: str, new: str) -> None:
        text = path.read_text(encoding="utf-8")
        assert old in text, f"self-test {name}: {path.name} does not contain {old!r}"
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    if name == "version-pin-drift":
        rewrite(reader, 'reviewedImplementationVersion = "0.0.12"',
                'reviewedImplementationVersion = "0.0.13"')
    elif name == "version-pin-literal":
        rewrite(composition,
                ".contentCredentialValidation: DefAIkeProvenanceC2PAModule"
                ".reviewedValidatorVersion,",
                '.contentCredentialValidation: "0.0.12",')
    elif name == "version-pin-not-from-module":
        rewrite(composition,
                "DefAIkeProvenanceC2PAModule.reviewedValidatorVersion,",
                "someOtherConstant,")
    elif name == "app-attests-nothing":
        # The surviving direction of the attestation check, and the only one left after the
        # merge: an application composition that compiles the capability must attest the
        # adapter version it links. The removed counterpart planted the opposite violation in
        # a pixel-only composition that no longer exists.
        rewrite(composition,
                ".contentCredentialValidation: DefAIkeProvenanceC2PAModule"
                ".reviewedValidatorVersion,",
                "")
    elif name == "loose-dependency-requirement":
        rewrite(package_swift,
                'url: "https://github.com/contentauth/c2pa-swift.git",\n            exact: '
                '"0.0.12"',
                'url: "https://github.com/contentauth/c2pa-swift.git",\n            from: '
                '"0.0.12"')
    elif name == "unapproved-package":
        rewrite(package_swift,
                "    dependencies: [\n",
                '    dependencies: [\n        .package(\n            url: '
                '"https://github.com/example/analytics-sdk.git",\n            exact: "1.0.0"\n'
                "        ),\n")
    elif name == "unapproved-resolved-package":
        text = json.loads(resolved.read_text(encoding="utf-8"))
        text["pins"].append(
            {
                "identity": "analytics-sdk",
                "kind": "remoteSourceControl",
                "location": "https://github.com/example/analytics-sdk.git",
                "state": {"revision": "0" * 40, "version": "1.0.0"},
            }
        )
        resolved.write_text(json.dumps(text, indent=2), encoding="utf-8")
    elif name == "analytics-import":
        (domain / "PlantedViolation.swift").write_text(
            "import AppTrackingTransparency\n", encoding="utf-8"
        )
    elif name == "network-symbol":
        (domain / "PlantedViolation.swift").write_text(
            "func planted() { _ = URLSession.shared }\n", encoding="utf-8"
        )
    elif name == "crash-handler-symbol":
        (domain / "PlantedViolation.swift").write_text(
            "func planted() { NSSetUncaughtExceptionHandler(nil) }\n", encoding="utf-8"
        )
    elif name == "account-entitlement":
        rewrite(entitlements, "<dict>",
                "<dict>\n\t<key>com.apple.developer.applesignin</key>\n\t<array/>")
    elif name == "advertising-info-key":
        rewrite(info, "<dict>", "<dict>\n\t<key>SKAdNetworkItems</key>\n\t<array/>")
    else:  # pragma: no cover - the table and this function are edited together.
        raise AssertionError(f"unknown self-test {name}")


def self_test_products(products: pathlib.Path) -> int:
    """Prove the archive checks can fail, against the one built archive.

    The static checks can be validated by planting a violation in a copied tree. An archive
    cannot: producing one that embeds a validator it should not would mean building a different
    project.

    Two archives used to make this easy. They differed in exactly the property under test, so
    each could be held to the other's rules and the finding had to appear. That probe is gone
    with the merge, and what replaces it is narrower but answers the same question — *can this
    inspection see a validator at all?* The composition's own `links_validator` is inverted for
    the length of one run, so the real bytes are held to the rule that they must contain no
    C2PA payload, and the payload, symbol, and module-reference checks must all fire.

    Nothing about the bytes is faked. Only the expectation is inverted, and it is restored in
    `finally`.

    What this can no longer probe is the opposite direction: that an archive genuinely without
    a validator is reported as missing one. No such application archive is built any more. The
    Share Extension's `.appex` is the remaining shipping bundle that must contain no validator,
    and `ios/Scripts/check-share-extension-target.py` is what audits it.
    """
    global FORBIDDEN_CLASSES  # noqa: PLW0603 - restored in `finally`
    print("Non-vacuity self-test over the built archive")
    composition = COMPOSITIONS[0]
    expectations: list[tuple[str, str, int]] = []

    # Hold the archive that does contain the validator to the rule that it must not.
    original_linkage = composition.links_validator
    try:
        composition.links_validator = False
        report = Report(quiet=True)
        check_products(products, None, report)
        for expected in [
            "embeds C2PA payload",
            "C2PA symbols",
            f"references {ADAPTER_MODULE}",
        ]:
            expectations.append(
                (
                    f"absence rules over the application archive: {expected}",
                    expected,
                    len([f for f in report.findings if expected in f]),
                )
            )
    finally:
        composition.links_validator = original_linkage

    # Attribution itself: the archive must refuse a name that is not its own. `pixel-only` is
    # used deliberately — it is the retired composition, so this also fails loudly if that name
    # is ever quietly reintroduced as a valid one.
    report = Report(quiet=True)
    check_products(products, "pixel-only", report)
    expectations.append(
        (
            "--expect pixel-only refused by the application archive",
            "disagrees with the archive",
            len([f for f in report.findings if "disagrees with the archive" in f]),
        )
    )

    # The forbidden-framework matcher, against a framework the archive is known to link.
    saved_classes = FORBIDDEN_CLASSES
    try:
        FORBIDDEN_CLASSES = [
            ForbiddenClass("probe", ["n/a"], "probe", [], [], ["CoreML"], [], [])
        ]
        report = Report(quiet=True)
        check_products(products, composition.name, report)
        expectations.append(
            (
                f"forbidden-framework matcher on {composition.name}",
                "links ['CoreML']",
                len([f for f in report.findings if "links ['CoreML']" in f]),
            )
        )
    finally:
        FORBIDDEN_CLASSES = saved_classes

    failures = 0
    for description, expected, count in expectations:
        if count:
            print(f"  PASS {description} ({count} finding(s))")
        else:
            failures += 1
            print(f"  FAIL {description}: no finding contained {expected!r}")
    print()
    if failures:
        print(f"archive self-test FAILED ({failures} of {len(expectations)} probes silent)")
        return 1
    print(f"archive self-test PASS ({len(expectations)} of {len(expectations)} probes fire)")
    return 0


def self_test() -> int:
    """Prove every static check can fail, by planting one real violation at a time."""
    print("Non-vacuity self-test")
    baseline = Report(quiet=True)
    run_static_checks(IOS, baseline)
    if baseline.findings:
        print("FAIL: the unmodified repository already has findings; self-test is meaningless")
        for finding in baseline.findings:
            print("  " + finding)
        return 1
    print(f"  baseline: {len(SELF_TESTS)} planted violations to check, 0 findings unmodified")

    failures = 0
    for name, expected in SELF_TESTS:
        with tempfile.TemporaryDirectory(prefix="t123-selftest-") as temporary:
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
            matched = [
                finding for finding in report.findings if expected in finding
            ]
            if matched:
                print(f"  PASS {name}: {matched[0][:110]}")
            else:
                failures += 1
                print(f"  FAIL {name}: no finding contained {expected!r}")
                for finding in report.findings:
                    print(f"        got: {finding[:110]}")
    print()
    if failures:
        print(f"self-test FAILED ({failures} of {len(SELF_TESTS)} checks did not fire)")
        return 1
    print(f"self-test PASS ({len(SELF_TESTS)} of {len(SELF_TESTS)} checks fire)")
    return 0


# MARK: - Driver

def run_static_checks(root: pathlib.Path, report: Report) -> None:
    report.say("Adapter version pin")
    check_version_pin(root, report)
    report.say("Declared external dependencies")
    check_declared_dependencies(root, report)
    report.say("Production sources")
    check_production_sources(root, report)
    report.say("Bundle declarations")
    check_bundle_declarations(root, report)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--products",
        type=pathlib.Path,
        help="a per-scheme build's products directory, for example "
        "/tmp/pixelonly/Build/Products/Debug-iphonesimulator",
    )
    parser.add_argument(
        "--expect",
        choices=[composition.name for composition in COMPOSITIONS],
        help="cross-check the composition the archive identifies itself as",
    )
    parser.add_argument("--json", type=pathlib.Path, help="write findings and facts to a file")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove every static check can fail, by planting one violation at a time",
    )
    parser.add_argument(
        "--self-test-products",
        type=pathlib.Path,
        metavar="PRODUCTS",
        help="prove the archive checks can fail, by holding the built archive to the rule "
        "that it must contain no validator",
    )
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()
    if arguments.self_test_products:
        return self_test_products(arguments.self_test_products)

    report = Report()
    run_static_checks(IOS, report)

    if arguments.products:
        print("Built archive")
        check_products(arguments.products, arguments.expect, report)
    else:
        print("Built archive")
        print("  skipped: pass --products to inspect one built archive")

    if report.observations:
        print()
        print("Observations (measured, not violations)")
        for observation in report.observations:
            print("  " + json.dumps(observation, sort_keys=True))

    if arguments.json:
        arguments.json.write_text(
            json.dumps(
                {
                    "findings": report.findings,
                    "observations": report.observations,
                    "facts": report.facts,
                },
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )
        print(f"\nwrote {arguments.json}")

    print()
    if report.findings:
        print(f"FAIL ({len(report.findings)} finding(s))")
        for finding in report.findings:
            print("  " + finding)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
