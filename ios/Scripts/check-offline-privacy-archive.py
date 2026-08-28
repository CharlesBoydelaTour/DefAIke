#!/usr/bin/env python3
"""Offline, endpoint, result-persistence, and model-delivery evidence over both built archives.

Task 12.5's archive half. It is deliberately **not** a third copy of the two audits that
already exist:

  * ``ios/Scripts/check-capability-composition.py`` (task 12.3) owns adapter version-pin
    coherence, the closed five-package external-dependency allowlist, the comment-and-string-
    stripped production-source scan for six forbidden dependency classes, both targets'
    `Info.plist` and entitlements key scans, and per-composition archive inspection with
    self-attribution through `CFBundleIdentifier`.
  * ``ios/Scripts/check-share-extension-target.py`` (task 12.2) owns the same for the `.appex`,
    and exports the one ``strip_swift`` every source scan in this repository uses.

This script **runs both of them** and requires them to pass, ingesting 12.3's ``--json`` facts
and observations rather than re-deriving them. Everything it adds is something neither one
does:

  1. **Per-compiled-object attribution over every object file, not just the eight package
     modules.** 12.3 globs ``DefAIke*.o`` in the *products* directory, which is one whole-module
     object per package module and nothing at all for the app and extension *targets'* own
     sources. This walks `Intermediates.noindex/**/Objects-normal/<arch>/*.o` too, so every
     compiled source file in both Xcode targets is attributed individually, per architecture.
     That is what turns "no DefAIke module references a network symbol" from a statement about
     eight linked blobs into a statement about every source file that reaches an archive.
  2. **The network capability split, measured and stated rather than assumed.** The application
     and its Share Extension differ in exactly this property, and the difference is the point:
     the `.appex` images carry zero network symbol references, and the app's
     `DefAIke.debug.dylib` carries thirteen — all of them arriving with the reviewed validator.
     This script measures both sides every run and refuses to let either be a comment.

     The absence half used to come from a pixel-only application archive. The two application
     compositions were merged into one, so it comes from the extension now — the remaining
     shipping bundle the Extension Execution Policy forbids any network code.
  3. **An endpoint inventory.** Neither existing script reads string data. This extracts every
     URL-like string from every Mach-O image in the archive and inventories the hosts, so
     "no unexpected endpoint" is a measurement.
  4. **A seventh forbidden class: result persistence and export.** 12.3's six classes are
     network model updates, analytics, advertising, account, custom diagnostics, and third-party
     crash reporting. Requirements 9.14, 9.15, and 9.17 forbid a different set of things —
     pasteboard, share sheet, document export, photo-library write, archived or database result
     storage, and any write into a persistent container domain — and no existing check looks for
     them. This one scans production sources, both plists, and the archive for their API
     surfaces.
  5. **Model-delivery evidence at the archive level (Requirements 10.20 and 10.21).** What the
     archive actually contains, what it declares, and whether any download API is attributable
     to `DefAIkeModelBundle` — rather than the type-level claim that
     `BundledModelDelivery` has one case.
  6. **A vendor static-archive network-stack inventory.** 12.3 recorded `URLSession` inside
     `C2PA.o` as a `third-party-symbol-reference` observation. The linked `C2PAC` slice is a
     420 MB static archive, and inventorying it is a strictly larger fact than that observation.
     Recorded as a Provenance Feasibility Gate input, never as a violation: nothing here added
     it, and removing it means removing the reviewed validator.

Usage:

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    xcodebuild build -workspace ios/DefAIke.xcworkspace -scheme DefAIkeApp \\
        -configuration Debug -destination 'generic/platform=iOS Simulator' \\
        -derivedDataPath /tmp/t125-DefAIkeApp CODE_SIGNING_ALLOWED=NO
    ios/Scripts/check-offline-privacy-archive.py --build /tmp/t125-DefAIkeApp

    ios/Scripts/check-offline-privacy-archive.py                     # static checks only
    ios/Scripts/check-offline-privacy-archive.py --self-test         # non-vacuity, static
    ios/Scripts/check-offline-privacy-archive.py --self-test-products \\
        --build DIR                                                  # non-vacuity, archive

``--build`` takes the ``-derivedDataPath`` *root*, not the products directory, because half of
what this script measures lives under `Intermediates.noindex`. The archive is attributed by its
own `CFBundleIdentifier` and cross-checked against the composition table, so a bundle built from
some other spec — or a stale one left in a shared derived-data path — is a finding rather than a
silently wrong report.

What this script does **not** do: run an Analysis Session. A session cannot be run from a shell
audit, and "networking unavailable" is established here by absence of the capability rather than
by a runtime observation. The session half is
`DefAIkeApplicationTests/OfflineSessionAndPrivacySmokeTests.swift`, and that file states
plainly what a host run does and does not establish. SBOM generation and `.xcarchive` auditing
remain task 14.6's; `--json` exists so it can consume these findings.
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
SCRIPTS = IOS / "Scripts"


def _load(name: str, filename: str):
    """Import a sibling audit script as a module, so its work is reused rather than copied."""
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The one stripper. A third one would be a third thing to keep correct, and 12.2 measured what
# an unstripped scan costs: 16 false positives across eight extension files, 36 across an
# earlier repository-wide audit.
_SHARE_EXTENSION_CHECK = _load("check_share_extension_target", "check-share-extension-target.py")
strip_swift = _SHARE_EXTENSION_CHECK.strip_swift

# 12.3's composition table, allowlist, and production-source roots, imported rather than
# restated so the two scripts cannot disagree about which archive is which.
_CAPABILITY_CHECK = _load("check_capability_composition", "check-capability-composition.py")
COMPOSITIONS = _CAPABILITY_CHECK.COMPOSITIONS
production_source_roots = _CAPABILITY_CHECK.production_source_roots

APP = COMPOSITIONS[0]

# The `.appex` path prefix inside the built `.app`.
#
# The Share Extension is the absence case now. While two application archives shipped, the
# pixel-only one carried zero network symbols and zero URL-like strings anywhere, and that
# zero was the non-vacuity partner for the provenance archive's non-zero counts: a scan
# reporting zero everywhere is indistinguishable from a broken scan. The two application
# compositions were merged, so the pairing moved inside the one archive. The extension's
# images are built from DefAIke objects alone and the Extension Execution Policy forbids
# them any network or provenance code, so their zero is a real measurement — verified
# against the built bytes, not assumed — and the app's non-zero counts in the same run are
# what prove the scanner works.
EXTENSION_PREFIX = "PlugIns/DefAIkeShareExtension.appex/"


# MARK: - Symbol vocabularies

# Every symbol below is matched as a **substring**, never with `\b`. That is measured, not
# stylistic: the reference a linked build actually carries is
# `_$sSo12NSURLSessionC10FoundationE4data3for8delegate…`, where `NSURLSession` has word
# characters on both sides, so a `\b`-anchored pattern matches nothing and the whole check
# silently measures zero. 12.3 hit exactly this. Source scans below keep `\b`, because there the
# input really is Swift text.

# Off-device transmission (Requirements 9.2, 9.3, 6.8, 10.20, 10.21).
NETWORK_SYMBOLS = [
    "URLSession",
    "NSURLSession",
    "URLRequest",
    "NSURLRequest",
    "NSURLConnection",
    "NWConnection",
    "NWListener",
    "NWPathMonitor",
    "WKWebView",
    "CFReadStreamCreate",
    "CFWriteStreamCreate",
    "CFHTTPMessage",
    "CFSocket",
    "_getaddrinfo",
    "_gethostbyname",
    "_socket",
    "_socketpair",
    "_connect",
    "_sendto",
    "_recvfrom",
]

# Result persistence, export, and sharing (Requirements 9.14, 9.15, 9.17).
PERSISTENCE_EXPORT_SYMBOLS = [
    "UIPasteboard",
    "NSPasteboard",
    "UIActivityViewController",
    "UIDocumentPickerViewController",
    "UIDocumentInteractionController",
    "UIActivityItemProvider",
    "NSSharingService",
    "PHPhotoLibrary",
    "PHAssetCreationRequest",
    "UIImageWriteToSavedPhotosAlbum",
    "NSKeyedArchiver",
    "NSPersistentContainer",
    "NSManagedObjectContext",
    "NSPersistentStoreCoordinator",
    "sqlite3_open",
    "sqlite3_exec",
    "NSUserDefaults",
    "NSUbiquitousKeyValueStore",
    "NSHTTPCookieStorage",
]


# MARK: - The seventh forbidden class, as source-level API surfaces

# API surfaces, not bare words. 12.3 measured why that distinction matters:
# `DefAIkePresentation/Disclosure/PrivacyDisclosureScreen.swift` legitimately contains the
# identifiers `advertisingIdentifier` and `analyticsIdentifier` as `AbsentDataPractice` cases
# *stating those things are absent*, so a bare-word pattern reports findings in correct code even
# after comments and string literals are stripped. The same trap applies here and harder:
# `ExcludedResultControl` names `saveResult`, `exportResult`, `copyResult`, and `shareResult`
# precisely because Version 1 has none of them, and `ProhibitedClaimAudit` matches on those very
# fragments. So every pattern below is an import, a framework type, or a Foundation search-path
# constant — something that cannot be written for any reason other than using it.
RESULT_PERSISTENCE_IMPORTS = [
    "CoreData",
    "SwiftData",
    "SQLite3",
    "CoreSpotlight",
    "QuickLook",
    "LinkPresentation",
    # `UniformTypeIdentifiers` is deliberately absent, and it was on this list until it was
    # measured. `DefAIkeImagePipeline/ContainerClassifier.swift`,
    # `ContentSignature.swift`, `EncodedImageSource.swift`, and
    # `DefAIkeShareExtension/Sources/ShareExtensionPlatform.swift` all import it to *classify an
    # incoming container*, which is Requirement 2.9's job. The module is a vocabulary of type
    # identifiers and exports nothing. Listing it produced four findings in correct code.
]

# The distinction this list has to draw, and did not on the first attempt: **direction**.
#
# `NSItemProvider`, `Transferable`, and `UTType` are all bidirectional. The Share Extension's
# inbound attachment *is* an `NSItemProvider` (`ShareExtensionPlatform.swift` names it at four
# code lines), and the Photos route's typed request *is* a `Transferable` whose five
# representations are every one of them `FileRepresentation(importedContentType:)`
# (`MainAppPlatform.swift:343`). Banning the type banned the ingest the application is built to
# perform: the first version of this list produced five findings in correct code on top of the
# four above.
#
# So what is banned below is the **export half** of each of those APIs — the registration calls,
# the `exportedContentType:` representations, the share and document-export presentation types —
# and never the type itself. Requirements 9.14, 9.15, and 9.17 forbid getting a *result* out,
# not getting an *image* in.
RESULT_PERSISTENCE_TYPES = [
    # Pasteboard (Requirement 9.15, copy-result).
    "UIPasteboard",
    "NSPasteboard",
    # Share sheet and outbound item registration (Requirement 9.15, share-result).
    "UIActivityViewController",
    "UIActivityItemSource",
    "UIActivityItemProvider",
    "ShareLink",
    "NSSharingService",
    "UIDocumentInteractionController",
    "registerDataRepresentation",
    "registerFileRepresentation",
    "registerCloudKitShare",
    "exportedContentType",
    # Document export (Requirement 9.15, export-result).
    "UIDocumentPickerViewController",
    "fileExporter",
    "FileDocument",
    "ReferenceFileDocument",
    "exportFiles",
    # Photo-library write (Requirement 9.15, save-result; also Requirement 9.4's
    # selected-item-only access, which a creation request would exceed).
    "PHPhotoLibrary",
    "PHAssetCreationRequest",
    "PHAssetChangeRequest",
    "UIImageWriteToSavedPhotosAlbum",
    # Result storage (Requirements 9.14, 9.15 analysis-history and save-result).
    "NSKeyedArchiver",
    "NSKeyedUnarchiver",
    "NSPersistentContainer",
    "NSManagedObjectContext",
    "NSPersistentStoreCoordinator",
    "ModelContainer",
    "ModelContext",
    "UserDefaults",
    "NSUserDefaults",
    "NSUbiquitousKeyValueStore",
    "CSSearchableItem",
    "NSHTTPCookieStorage",
    "AppStorage",
    "SceneStorage",
]

# Foundation search-path domains that outlive a session. A session's material belongs in the
# ephemeral store, which is built over the temporary and App Group containers; a write into any
# domain below is persistence by definition. `.cachesDirectory` is included: it survives an app
# launch, so an Evidence Report written there would outlive its session (Requirement 9.14).
PERSISTENT_SEARCH_PATH_DOMAINS = [
    "documentDirectory",
    "applicationSupportDirectory",
    "libraryDirectory",
    "cachesDirectory",
    "applicationDirectory",
    "picturesDirectory",
    "downloadsDirectory",
    "NSDocumentDirectory",
    "NSApplicationSupportDirectory",
    "NSCachesDirectory",
]

# Declaration keys that would announce an export, sharing, or indexing surface.
RESULT_PERSISTENCE_INFO_KEYS = [
    "UISupportsDocumentBrowser",
    "LSSupportsOpeningDocumentsInPlace",
    "CFBundleDocumentTypes",
    "UTExportedTypeDeclarations",
    "NSPhotoLibraryAddUsageDescription",
    "CSSearchableItemActivityIdentifier",
    "NSUserActivityTypes",
]
RESULT_PERSISTENCE_ENTITLEMENTS = [
    "com.apple.developer.ubiquity-container-identifiers",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.developer.coremedia.allow-alternate-video-decoder-selection",
]

# Info.plist keys that would name a model-update or asset-download endpoint (Requirement 10.21).
MODEL_UPDATE_INFO_KEYS = [
    "NSAppTransportSecurity",
    "BGTaskSchedulerPermittedIdentifiers",
    "MLModelUpdateURL",
    "ModelUpdateEndpoint",
    "NSBundleResourceRequestTag",
    "CFBundleURLTypes",
]

# The vendor crates whose presence in the linked static archive is a Provenance Feasibility Gate
# input. Each is an HTTP client, an HTTP/2 implementation, a TLS implementation, a root-store
# bundle, or the async runtime they need.
VENDOR_NETWORK_CRATES = [
    "reqwest",
    "hyper_rustls",
    "hyper_util",
    "hyper",
    "h2",
    "rustls",
    "webpki",
    "tokio",
]

# A URL-like string, deliberately loose: an over-inclusive pattern that then reports what it
# found is honest, and a tight one that quietly drops an endpoint is not.
URL_PATTERN = re.compile(r"(?:https?|wss?|ftp)://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+")

# URLs that code signing puts in a binary, which no DefAIke source contains.
#
# Measured: `codesign` embeds the entitlements as an XML plist, and that plist's DOCTYPE line
# names the property-list DTD. So a *signed* build carries this string in every image that has
# an entitlements blob, including the Share Extension's — whose own sources contain no URL at
# all. An unsigned build (`CODE_SIGNING_ALLOWED=NO`) carries none, which is why an earlier
# measurement of this archive reported zero and a signed one reports one per image.
#
# Excluded by exact match, not by host: allowing anything under `apple.com` would let a real
# Apple endpoint through. A DOCTYPE identifier is not an endpoint a build contacts — nothing
# resolves it, and `allowedNetworkHosts: []` would refuse it if anything tried — but leaving it
# in the count would make the Share Extension's absence assertion fire on every signed build,
# and an assertion that always fires gets relaxed rather than read.
#
# The filtered count is reported in the inventory observation rather than dropped silently.
SIGNING_ARTIFACT_URLS = frozenset({"http://www.apple.com/DTDs/PropertyList-1.0.dtd"})

# What a plausible host looks like, applied *after* matching rather than instead of it.
#
# Measured: the provenance archive's `DefAIke.debug.dylib` yields 73 distinct authority strings
# under the loose pattern, and most are not hosts at all — `http://.css`, `http://px;`, and a
# 74-character run beginning `dictionaryperception…` are fragments of the Brotli and Zstandard
# built-in dictionaries, which contain compressed English web text. Reporting all 73 as "hosts"
# buried the eight real ones. So the inventory now separates them: a match whose authority looks
# like a hostname is listed by name, and everything else is *counted* under
# `unparseableAuthorities` rather than dropped. The pixel-only assertion below still runs on the
# raw match count, which is zero, so nothing is weakened by the split.
PLAUSIBLE_HOST = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$")

# Object-file paths that are DefAIke's own code. Anything else compiled into an archive
# arrived with a reviewed dependency, and the difference is the whole point of attribution.
DEFAIKE_OBJECT_ROOTS = ["DefAIkePackage.build", "DefAIke.build"]

# Package module and Xcode target build directories every archive must contain. Required rather
# than discovered, so an inspection that found no objects — a moved derived-data path, a build
# that never linked — fails instead of reporting a clean pass over nothing.
REQUIRED_OBJECT_OWNERS = {
    "DefAIkeDomain",
    "DefAIkeSharedTransfer",
    "DefAIkeApplication",
    "DefAIkeImagePipeline",
    "DefAIkeModelBundle",
    "DefAIkeCoreML",
    "DefAIkeProvenanceAPI",
    "DefAIkePresentation",
}


# MARK: - Findings

class Report:
    """Collects findings, observations, and measured facts so one run reports all of them."""

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


# MARK: - Mach-O and object helpers

MACH_O_MAGIC = {
    b"\xcf\xfa\xed\xfe",  # 64-bit little-endian
    b"\xce\xfa\xed\xfe",  # 32-bit little-endian
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",  # universal
    b"\xbe\xba\xfe\xca",
}


def is_mach_o(path: pathlib.Path) -> bool:
    """Whether `path` starts with a Mach-O or universal-binary magic number.

    Reading four bytes rather than shelling out to `file` once per candidate: an app bundle has
    hundreds of files and the answer is in the header.
    """
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACH_O_MAGIC
    except OSError:
        return False


def run_tool(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"{command[1]} failed")
    return result.stdout


def run_tolerating_partial_failure(command: list[str]) -> tuple[str, int]:
    """Run a tool that may report per-member errors and still produce usable output.

    Needed for exactly one input, and measured rather than anticipated: `nm` over the thinned
    `C2PAC` archive exits non-zero because hundreds of its members were produced by
    `LLVM22.1.2-rust-1.96.0-stable`, whose bitcode carries an attribute kind Xcode 26's reader
    does not know, and several `compiler_builtins` members legitimately define no symbols. It
    still emits every symbol it *could* read on stdout. Treating that as a hard failure lost the
    whole inventory; treating it as success would hide that the read was partial. So both are
    returned, and the observation records the number of unreadable members alongside the counts.
    """
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if not result.stdout.strip():
        raise RuntimeError(result.stderr.strip() or f"{command[1]} produced no output")
    return result.stdout, len(
        [line for line in result.stderr.splitlines() if ": error: " in line]
    )


def undefined_symbols(path: pathlib.Path) -> str:
    return run_tool(["xcrun", "nm", "-u", str(path)])


def image_strings(path: pathlib.Path) -> str:
    return run_tool(["xcrun", "strings", "-a", str(path)])


def mach_o_images(app: pathlib.Path) -> list[pathlib.Path]:
    """Every Mach-O image a built bundle carries, at any depth.

    A Debug build puts the module's own code in `<Name>.debug.dylib` and leaves a thin `<Name>`
    shim, and the network references this script is about are in the dylib rather than the shim.
    So every file is tested by its header rather than by its name or its position, and plug-ins
    and embedded frameworks are walked too.
    """
    return sorted(path for path in app.rglob("*") if path.is_file() and is_mach_o(path))


def compiled_objects(build_root: pathlib.Path) -> list[pathlib.Path]:
    """Every `.o` a build produced, from both the products directory and the intermediates.

    The products directory holds one whole-module object per package module — what 12.3 reads.
    `Intermediates.noindex/**/Objects-normal/<arch>/` holds one object per *source file*, for
    the package modules and for the app and Share Extension Xcode targets, whose sources have no
    products-directory object at all. Both are included, because the second is the only place
    `MainAppComposition.swift` or `ShareViewController.swift` can be attributed individually.
    """
    products = build_root / "Build" / "Products"
    intermediates = build_root / "Build" / "Intermediates.noindex"
    objects = sorted(products.rglob("*.o")) + sorted(intermediates.rglob("*.o"))
    return objects


def object_owner(path: pathlib.Path) -> str | None:
    """The module or Xcode target a compiled object belongs to, or `None` when unattributable.

    Two shapes exist. A products-directory object is `<Module>.o` and names its module directly.
    An intermediates object sits under `<Owner>.build/Objects-normal/<arch>/<Source>.o`, where
    `<Owner>` is the package module or Xcode target — the level attribution needs, since the
    source-file name alone would not say whose code it is.
    """
    for parent in path.parents:
        if parent.name.endswith(".build"):
            return parent.name.removesuffix(".build")
    if path.parent.name.startswith("Debug") or path.parent.name.startswith("Release"):
        return path.stem
    return None


def is_defaike_object(path: pathlib.Path) -> bool:
    """Whether a compiled object is DefAIke's own code rather than a dependency's.

    An intermediates object is DefAIke's when it sits under either build root: the package's
    own `.build` tree or the Xcode project's. A products-directory object is DefAIke's when
    its whole-module name says so — `C2PA.o`, `Crypto.o`, and `SwiftASN1.o` sit in the same
    directory as `DefAIkeDomain.o` and are exactly what must not be conflated with it.
    """
    parts = set(path.parts)
    if any(root in parts for root in DEFAIKE_OBJECT_ROOTS):
        # Under the package build root, a dependency's module has its own `.build` directory,
        # so the owner name is what distinguishes them.
        owner = object_owner(path)
        return bool(owner and owner.startswith("DefAIke"))
    return path.stem.startswith("DefAIke")


# MARK: - Layer 0: the two existing audits

def delegate_to_existing_audits(
    builds: dict[str, pathlib.Path | None], report: Report
) -> None:
    """Run 12.3's and 12.2's audits and require them to pass, ingesting 12.3's JSON.

    Running them rather than restating them is the point: every claim they already make stays
    theirs, this script's findings are only the ones they do not make, and a regression in either
    surfaces here instead of being masked by a green run of a narrower audit.
    """
    for composition in COMPOSITIONS:
        build_root = builds.get(composition.name)
        products = (
            build_root / "Build" / "Products" / "Debug-iphonesimulator"
            if build_root
            else None
        )
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
            json_path = pathlib.Path(handle.name)
        command = [
            sys.executable,
            str(SCRIPTS / "check-capability-composition.py"),
            "--json",
            str(json_path),
        ]
        if products is not None:
            command += ["--products", str(products), "--expect", composition.name]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
        try:
            delegated = json.loads(json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            report.fail(f"12.3's audit produced no readable JSON for {composition.name}: {error}")
            delegated = {"findings": ["<unreadable>"], "observations": [], "facts": {}}
        finally:
            json_path.unlink(missing_ok=True)

        report.require(
            result.returncode == 0 and not delegated["findings"],
            f"check-capability-composition.py failed for {composition.name}: "
            + "; ".join(delegated["findings"][:4]),
        )
        report.facts[f"delegated.capability.{composition.name}"] = delegated["facts"]
        for observation in delegated["observations"]:
            # 12.3's observations already carry their own `kind`, so they are nested rather than
            # merged. Flattening them would either collide on that key or silently relabel a
            # finding class another task named.
            report.observe(
                "delegated-capability-observation",
                composition=composition.name,
                delegated=observation,
            )
        report.say(
            f"  {composition.name}: 12.3's audit reports {len(delegated['findings'])} "
            f"finding(s), {len(delegated['observations'])} observation(s)"
        )

        if products is None:
            continue
        extension_result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "check-share-extension-target.py"),
                "--products",
                str(products),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        # 12.2's script has no `--json`, so its exit code is the result and its last output line
        # is the best available detail. Built as a statement rather than a conditional expression
        # inside the call, because a ternary spanning a concatenation is exactly the shape that
        # reads as one thing and evaluates as another.
        detail = ""
        lines = extension_result.stdout.strip().splitlines()
        if extension_result.returncode != 0 and lines:
            detail = ": " + lines[-1]
        report.require(
            extension_result.returncode == 0,
            f"check-share-extension-target.py failed for {composition.name}{detail}",
        )
        report.say(
            f"  {composition.name}: 12.2's `.appex` audit "
            f"{'PASS' if extension_result.returncode == 0 else 'FAIL'}"
        )


# MARK: - Layer 1: result persistence and export, in production sources

def check_result_persistence_sources(root: pathlib.Path, report: Report) -> None:
    """Scan every production source for a result-persistence, export, or sharing API surface.

    Requirements 9.14, 9.15, and 9.17. This is the class 12.3 does not have: its six classes are
    about telemetry and remote updates, and none of its patterns would notice a pasteboard write
    or a Core Data store.

    ``strip_swift`` first, always. Comments and string literals in this repository name every one
    of these surfaces on purpose — `ExcludedResultControl`'s whole documentation is an
    enumeration of the affordances that must not exist — and an unstripped scan would report the
    prohibition itself as a violation.
    """
    patterns: list[tuple[re.Pattern[str], str]] = []
    for name in RESULT_PERSISTENCE_IMPORTS:
        patterns.append((re.compile(rf"\bimport\s+{re.escape(name)}\b"), f"imports {name}"))
    for name in RESULT_PERSISTENCE_TYPES:
        patterns.append((re.compile(rf"\b{re.escape(name)}\b"), f"names {name}"))
    for name in PERSISTENT_SEARCH_PATH_DOMAINS:
        patterns.append(
            (
                re.compile(rf"\b{re.escape(name)}\b"),
                f"names the persistent search-path domain {name}",
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
                for pattern, why in patterns:
                    if pattern.search(line):
                        report.fail(
                            f"result-persistence-or-export: "
                            f"{path.relative_to(root)}:{number} {why}: {line.strip()}"
                        )
    report.require(scanned > 0, "no production Swift sources were scanned for persistence")
    report.facts["persistenceSourcesScanned"] = scanned
    report.say(
        f"  scanned {scanned} production sources for "
        f"{len(patterns)} persistence, export, and sharing surfaces"
    )


def check_result_persistence_declarations(root: pathlib.Path, report: Report) -> None:
    """Scan both targets' plists for a declared export, sharing, indexing, or update surface."""
    files = [
        root / "DefAIkeApp" / "Support" / "Info.plist",
        root / "DefAIkeApp" / "Support" / "DefAIkeApp.entitlements",
        root / "DefAIkeShareExtension" / "Support" / "Info.plist",
        root / "DefAIkeShareExtension" / "Support" / "DefAIkeShareExtension.entitlements",
    ]
    banned = set(
        RESULT_PERSISTENCE_INFO_KEYS + RESULT_PERSISTENCE_ENTITLEMENTS + MODEL_UPDATE_INFO_KEYS
    )
    checked = 0
    for path in files:
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
        declared = sorted(set(contents) & banned)
        report.require(
            not declared,
            f"result-persistence-or-export: {path.name} declares {declared}",
        )
    report.facts["persistenceDeclarationFilesChecked"] = checked
    report.say(f"  checked {checked} declaration files for export and update keys")


# MARK: - Layer 2: per-compiled-object attribution

def check_object_attribution(
    composition_name: str, build_root: pathlib.Path, report: Report
) -> None:
    """Require every DefAIke compiled object to reference no network, export, or storage API.

    This is the strongest evidence available for "no network API is reachable from the analysis
    path", and it is stronger than a linked-image scan in the one way that matters: a linked
    image is a single unit, so a symbol found in it cannot be blamed on anybody, while an object
    file can. It is also stronger than 12.3's products-directory glob, which sees one object per
    package module and none at all for the app or extension targets' own sources.

    Every architecture the build produced is scanned. The Release two-architecture setting is
    exactly the condition a Phase C repair had to fix once, so measuring one slice and reporting
    it as "the build" would be the wrong shape of claim.
    """
    objects = compiled_objects(build_root)
    report.require(
        bool(objects),
        f"{composition_name}: {build_root} contains no compiled objects; point "
        "--{composition}-build at a -derivedDataPath root rather than a products directory",
    )
    if not objects:
        return

    defaike = [path for path in objects if is_defaike_object(path)]
    owners = {object_owner(path) for path in defaike} - {None}
    architectures = {
        path.parent.name
        for path in defaike
        if path.parent.parent.name == "Objects-normal"
    }

    missing = REQUIRED_OBJECT_OWNERS - {owner for owner in owners if owner}
    report.require(
        not missing,
        f"{composition_name}: no compiled objects were found for {sorted(missing)}, so their "
        "sources were not attributed and this check would pass without having examined them",
    )
    report.require(
        bool(architectures),
        f"{composition_name}: no per-architecture object directories were found, so the scan "
        "covered whole-module objects only",
    )

    checked = 0
    for path in defaike:
        try:
            undefined = undefined_symbols(path)
        except RuntimeError as error:
            report.fail(f"{composition_name}: {path.name}: nm failed: {error}")
            continue
        checked += 1
        owner = object_owner(path) or path.stem
        located = f"{owner}/{path.name}"
        if path.parent.parent.name == "Objects-normal":
            located = f"{owner}/{path.parent.name}/{path.name}"
        for symbol in NETWORK_SYMBOLS:
            report.require(
                symbol not in undefined,
                f"offline: {composition_name}: {located} references the network symbol {symbol}; "
                "an Analysis Session must complete with connectivity disabled "
                "(Requirements 6.8, 9.3, 10.20)",
            )
        for symbol in PERSISTENCE_EXPORT_SYMBOLS:
            report.require(
                symbol not in undefined,
                f"result-persistence-or-export: {composition_name}: {located} references "
                f"{symbol} (Requirements 9.14, 9.15, 9.17)",
            )

    report.facts[f"{composition_name}.objectsScanned"] = checked
    report.facts[f"{composition_name}.objectOwners"] = sorted(o for o in owners if o)
    report.facts[f"{composition_name}.objectArchitectures"] = sorted(architectures)
    # Counted and sampled rather than listed in full. The provenance build compiles more than
    # 1,400 dependency objects — every BoringSSL assembly variant has one — and writing all of
    # their names into `--json` would hand task 14.6 tens of kilobytes of noise. The count is the
    # fact that matters: it says how much of the archive is *not* covered by the AI-Buster-owned
    # assertion above, which is what makes that assertion's scope honest.
    dependency_objects = sorted({path.stem for path in objects if not is_defaike_object(path)})
    report.facts[f"{composition_name}.dependencyObjectCount"] = len(dependency_objects)
    report.facts[f"{composition_name}.dependencyObjectSample"] = dependency_objects[:40]
    report.say(
        f"  {composition_name}: {checked} DefAIke objects across "
        f"{len(owners)} owners and {sorted(architectures)}, "
        f"0 network or persistence references required "
        f"({len(dependency_objects)} dependency objects out of scope, attributed by 12.3)"
    )


# MARK: - Layer 3: the composition asymmetry

def measure_image_symbols(
    composition_name: str, products: pathlib.Path, report: Report
) -> dict[str, list[str]]:
    """Count network symbol references per Mach-O image, and attribute each one.

    Returns the per-image reference map so the caller can state the split between the
    application and the Share Extension rather than assert the archive in isolation.
    """
    app = products / "DefAIke.app"
    if not app.is_dir():
        report.fail(f"{app} does not exist")
        return {}

    info_path = app / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            identifier = plistlib.load(handle).get("CFBundleIdentifier", "")
    except (OSError, plistlib.InvalidFileException) as error:
        report.fail(f"{info_path} is not a readable plist: {error}")
        return {}
    expected = {c.name: c.bundle_identifier for c in COMPOSITIONS}[composition_name]
    report.require(
        identifier == expected,
        f"the archive at {products} identifies itself as {identifier!r}, but it was supplied as "
        f"the {composition_name} archive, which is {expected!r}; the wrong build was supplied "
        "or a stale bundle is present in this derived-data path",
    )
    if identifier != expected:
        return {}

    references: dict[str, list[str]] = {}
    for image in mach_o_images(app):
        try:
            undefined = undefined_symbols(image)
        except RuntimeError as error:
            report.fail(f"{composition_name}: {image.name}: nm failed: {error}")
            continue
        named = sorted(symbol for symbol in NETWORK_SYMBOLS if symbol in undefined)
        references[str(image.relative_to(app))] = named
    return references


def check_network_capability_split(
    measured: dict[str, list[str]],
    build_root: pathlib.Path,
    report: Report,
) -> None:
    """State the archive's network-capability split, both halves of it.

    The archive is **not** uniform, and a check that implied otherwise would be wrong:

      * The **Share Extension**'s images reference no network symbol at all. Its offline
        guarantee is that the capability is absent from the shipped bytes, which the
        Extension Execution Policy requires (Requirement 2.6).
      * The **application**'s main image statically links the reviewed validator, and the
        validator brings a network client with it. So its offline guarantee rests on
        `C2PALibraryReader.applyOfflineSettings` — `remoteManifestFetch: false`,
        `ocspFetch: false`, `allowedNetworkHosts: []` — at **runtime**, not on absence.

    Neither is a violation of this task, and the second is not a violation of 12.3's
    "remove the dependency" clause either: nothing DefAIke wrote added it, and removing it
    means removing the reviewed validator. What this check requires is that the split be
    measured and attributed every run — that the extension really is empty, that every
    application reference really is attributable to a non-AI-Buster object, and that the
    difference is recorded as a Provenance Feasibility Gate input rather than described in a
    comment.

    This used to compare two application archives. It compares two bundles inside one archive
    now, for the reason `EXTENSION_PREFIX` records: the asymmetry is what makes the
    measurement non-vacuous, and it had to be found somewhere real after the merge.
    """
    extension = {
        image: symbols
        for image, symbols in measured.items()
        if image.startswith(EXTENSION_PREFIX)
    }
    application = {
        image: symbols
        for image, symbols in measured.items()
        if not image.startswith(EXTENSION_PREFIX)
    }

    report.require(
        bool(extension),
        f"offline: no Share Extension image was found under {EXTENSION_PREFIX}; without it "
        "the application's network-symbol counts have no absence case to be measured against",
    )
    extension_total = sum(len(symbols) for symbols in extension.values())
    report.require(
        extension_total == 0,
        f"offline: the Share Extension references {extension_total} network symbol(s): "
        + json.dumps({k: v for k, v in extension.items() if v}, sort_keys=True)
        + "; the Share Extension must carry no transmission capability at all",
    )

    # The application side is attributed, not asserted away. Every referenced symbol must
    # belong to a dependency object or to the linked static archive; one belonging to an
    # DefAIke object would be this task's finding rather than the gate's input.
    products = build_root / "Build" / "Products" / "Debug-iphonesimulator"
    referenced = sorted({symbol for symbols in application.values() for symbol in symbols})
    attribution: dict[str, list[str]] = {}
    for symbol in referenced:
        owners: set[str] = set()
        for path in sorted(products.glob("*.o")):
            try:
                if symbol in undefined_symbols(path):
                    owners.add(path.stem)
            except RuntimeError:
                continue
        attribution[symbol] = sorted(owners)
    defaike_owned = {
        symbol: owners
        for symbol, owners in attribution.items()
        if any(owner.startswith("DefAIke") for owner in owners)
    }
    report.require(
        not defaike_owned,
        "offline: the application references network symbols from DefAIke modules "
        + json.dumps(defaike_owned, sort_keys=True)
        + "; a reference from DefAIke's own code is a violation rather than a supply-chain fact",
    )

    application_total = sum(len(symbols) for symbols in application.values())
    unattributed = sorted(symbol for symbol, owners in attribution.items() if not owners)
    report.observe(
        "network-capability-split",
        requirements=["2.6", "6.8", "9.2", "9.3", "10.19", "10.20", "10.21"],
        shareExtensionNetworkSymbolReferences=extension_total,
        applicationNetworkSymbolReferences=application_total,
        applicationImages={k: v for k, v in application.items() if v},
        attributedTo=attribution,
        unattributedToAnyProductsObject=unattributed,
        shareExtensionGuarantee="the capability is absent from the shipped bytes",
        applicationGuarantee=(
            "the capability is present in the shipped bytes and suppressed at runtime by "
            "C2PALibraryReader.applyOfflineSettings (remoteManifestFetch: false, "
            "ocspFetch: false, allowedNetworkHosts: [])"
        ),
        alsoLinked=(
            "The application additionally compiles swift-certificates' OCSP client "
            "(OCSPPolicy, OCSPRequest, OCSPResponse, BasicOCSPResponse) and its "
            "TrustRootLoading, plus WebServiceSigner, KeychainSigner, and "
            "SecureEnclaveSigner from c2pa-swift. None is referenced by any DefAIke "
            "object; all are reachable Swift code in the archive. `ocspFetch: false` is "
            "therefore a runtime setting over a present client rather than a statement "
            "about absent code, which is what the Provenance Policy's "
            "revocation-without-network behaviour has to be evaluated against."
        ),
        note=(
            "Not a violation. Symbols with no owning products object arrive from the linked "
            "C2PAC static archive, which is not published to the products directory."
        ),
    )
    report.facts["shareExtensionNetworkSymbolReferences"] = extension_total
    report.facts["applicationNetworkSymbolReferences"] = application_total
    report.say(
        f"  split: Share Extension {extension_total} network symbol reference(s), "
        f"application {application_total}, none attributable to an DefAIke module"
    )
    report.say(
        f"  application references attributed to "
        f"{sorted({o for v in attribution.values() for o in v})}"
        f"; unattributable to a products object: {unattributed}"
    )


# MARK: - Layer 4: the endpoint inventory

def check_endpoints(
    composition_name: str, products: pathlib.Path, report: Report
) -> dict[str, int]:
    """Inventory every URL-like string in every Mach-O image of one archive.

    Neither existing script reads string data at all, so "no unexpected endpoint" has never been
    measured. The pattern is deliberately loose and the inventory reports what it matched:
    compressed-dictionary fragments and truncated XMP namespaces both match `http://`, and an
    audit that silently tightened its pattern until the output looked clean would be worthless.

    The requirement is per-image and attributed rather than global: an image built entirely from
    DefAIke objects must contain no URL-like string, and an image that links the reviewed
    validator may contain the specification namespaces and vendor diagnostic URLs it ships.
    """
    app = products / "DefAIke.app"
    hosts_per_image: dict[str, int] = {}
    if not app.is_dir():
        report.fail(f"{app} does not exist")
        return hosts_per_image

    named_hosts: dict[str, list[str]] = {}
    unparseable: dict[str, int] = {}
    signing_artifacts_per_image: dict[str, int] = {}
    for image in mach_o_images(app):
        try:
            text = image_strings(image)
        except RuntimeError as error:
            report.fail(f"{composition_name}: {image.name}: strings failed: {error}")
            continue
        relative = str(image.relative_to(app))
        matches = URL_PATTERN.findall(text)
        signing_artifacts = sum(1 for match in matches if match in SIGNING_ARTIFACT_URLS)
        if signing_artifacts:
            signing_artifacts_per_image[relative] = signing_artifacts
        authorities = {
            match.split("//", 1)[1].split("/", 1)[0].split(":", 1)[0]
            for match in matches
            if match not in SIGNING_ARTIFACT_URLS
        }
        hosts = sorted(a for a in authorities if PLAUSIBLE_HOST.match(a))
        # The raw match count, not the plausible-host count, is what the pixel-only assertion
        # runs on. A build that named an endpoint in a form this filter rejects would still be
        # caught.
        hosts_per_image[relative] = len(authorities)
        if hosts:
            named_hosts[relative] = hosts
        if len(authorities) - len(hosts):
            unparseable[relative] = len(authorities) - len(hosts)

    report.facts[f"{composition_name}.urlAuthoritiesPerImage"] = hosts_per_image
    report.facts[f"{composition_name}.namedHosts"] = named_hosts
    report.observe(
        "archive-endpoint-inventory",
        composition=composition_name,
        requirements=["9.2", "9.3", "10.21"],
        urlLikeAuthoritiesPerImage=hosts_per_image,
        codeSigningDoctypeUrlsExcluded=signing_artifacts_per_image,
        namedHosts=named_hosts,
        unparseableAuthorities=unparseable,
        note=(
            "A URL-like string is not an endpoint a build contacts. The pattern is loose on "
            "purpose; `namedHosts` lists every match shaped like a hostname and "
            "`unparseableAuthorities` counts the rest rather than dropping them. In this "
            "archive the named hosts are C2PA, XMP, IPTC, and schema.org specification "
            "namespaces plus vendor diagnostic URLs, all carried inside the reviewed "
            "validator; the unparseable remainder is Brotli and Zstandard built-in "
            "dictionary text, which contains compressed English web content. The Share "
            "Extension's images contain zero of either once the code-signing DOCTYPE URL is "
            "excluded — see codeSigningDoctypeUrlsExcluded and SIGNING_ARTIFACT_URLS — which is "
            "the absence case that keeps this scan non-vacuous. The hostname filter is a "
            "heuristic and says so: seven of "
            "the application's named hosts (`www.years`, `www.css`, and "
            "similar) are dictionary fragments that happen to be shaped like hostnames. The "
            "filter is deliberately not tightened further, because a tighter one risks dropping "
            "a real endpoint, and the assertion this inventory supports runs on the raw count."
        ),
    )
    report.say(
        f"  {composition_name}: URL-like authorities per image "
        + json.dumps(hosts_per_image, sort_keys=True)
    )
    if named_hosts:
        report.say(f"  {composition_name}: named hosts " + json.dumps(named_hosts, sort_keys=True))
    return hosts_per_image


def check_share_extension_has_no_endpoint(
    hosts_per_image: dict[str, int], report: Report
) -> None:
    """Require the Share Extension's images to contain no URL-like string.

    Measured, not hoped for: every `.appex` image contains zero. That makes it the non-vacuity
    partner for the application inventory — a scan reporting zero everywhere would be
    indistinguishable from a broken scan, and the application's non-zero count in the same run
    rules that out.

    This ran on a pixel-only application archive before the two compositions were merged. The
    extension is the shipping bundle that still provably names no endpoint, so the pairing moved
    there rather than being dropped.
    """
    extension = {
        image: count
        for image, count in hosts_per_image.items()
        if image.startswith(EXTENSION_PREFIX)
    }
    report.require(
        bool(extension),
        f"offline: no Share Extension image was found under {EXTENSION_PREFIX}; without it the "
        "application's URL-string inventory has no absence case to be measured against",
    )
    offending = {image: count for image, count in extension.items() if count}
    report.require(
        not offending,
        "offline: the Share Extension contains URL-like strings "
        + json.dumps(offending, sort_keys=True)
        + "; the Share Extension names no endpoint at all",
    )


# MARK: - Layer 5: model delivery

def check_model_delivery(
    composition_name: str, build_root: pathlib.Path, report: Report
) -> None:
    """What the archive carries and declares about the model, at the archive level.

    Requirement 10.20 verifies and activates the Initial Model Bundle with connectivity
    disabled, and Requirement 10.21 uses only locally bundled artifacts and issues no network
    query, discovery, or download request for a model update. The type-level half of that —
    `BundledModelDelivery` having exactly one case, `packagedInsideApplication` — is already
    asserted by the presentation suites. This is the archive-level half, and it reports two
    different things:

      * the **negative** half of 10.21, which this build satisfies: no download API is
        attributable to `DefAIkeModelBundle`, and neither `Info.plist` declares an update
        endpoint, a background-refresh identifier, or a resource-request tag; and
      * the **positive** half of 10.1 and 10.20, which this build does **not** satisfy. That is
        recorded as a gap observation rather than silently passed, and rather than reported as a
        12.5 violation: producing and embedding a signed Initial Model Bundle is task 14.5's and
        the release process's, not this audit's.

        Two shapes of that gap, and both are observed rather than either being a pass. A Release
        archive carries no Core ML artifact at all (`bundled-model-absent`). A Debug archive
        carries the *development* model `ios/project.yml` compiles into it, which is an
        unverified `.mlpackage` behind a fabricated activation receipt
        (`bundled-model-unverified`). Bytes being present is not the claim 10.1 makes; a signed
        manifest and a measured activation receipt are, and neither exists.
    """
    products = build_root / "Build" / "Products" / "Debug-iphonesimulator"
    app = products / "DefAIke.app"
    if not app.is_dir():
        report.fail(f"{app} does not exist")
        return

    artifacts = sorted(
        str(path.relative_to(app))
        for pattern in ("*.mlmodel", "*.mlmodelc", "*.mlpackage", "*.mlmodelc/*")
        for path in app.rglob(pattern)
    )
    manifests = sorted(
        str(path.relative_to(app))
        for pattern in ("*ModelBundle*", "*model-bundle*", "*manifest.json")
        for path in app.rglob(pattern)
    )

    if not artifacts:
        report.observe(
            "bundled-model-absent",
            composition=composition_name,
            requirements=["10.1", "10.3", "10.20"],
            coreMLArtifacts=artifacts,
            bundleLikeFiles=manifests,
            note=(
                "Requirement 10.1 packages the Initial Model Bundle inside the distributed "
                "application, and this archive contains no Core ML artifact. So "
                "'packaged inside the application' cannot be established positively from these "
                "bytes; only the absence of a fetch path can. Reported, not fixed: task 14.5 "
                "built the bundle creation and verification tooling, and no produced bundle is "
                "embedded in a build yet."
            ),
        )
        report.say(
            f"  {composition_name}: no Core ML artifact in the archive; "
            "10.1's positive claim is unestablishable from these bytes (observation)"
        )
    else:
        # A Core ML artifact being present does NOT retire the 10.1 gap, and this branch exists
        # so that cannot be misread. A Debug build carries the development model
        # `ios/project.yml` compiles into it — an unverified `.mlpackage` behind a fabricated
        # activation receipt, `EXCLUDED_SOURCE_FILE_NAMES`-excluded from Release for exactly this
        # reason. Requirement 10.1 wants a *signed* Initial Model Bundle whose digests
        # `ModelBundleActivator` measured, and no such artifact exists.
        #
        # So the presence of bytes is recorded as what it is: a development model, not evidence.
        # The distinguishing observable is the absence of an activation receipt or signed manifest
        # alongside it, which is what `manifests` collects.
        report.observe(
            "bundled-model-unverified",
            composition=composition_name,
            requirements=["10.1", "10.3", "10.20"],
            coreMLArtifacts=artifacts,
            bundleLikeFiles=manifests,
            note=(
                "This archive carries a Core ML artifact, and that does not establish "
                "Requirement 10.1. A Debug build compiles the development model named in "
                "ios/project.yml into the bundle so a physical-device build can run inference "
                "at all; it is an unverified model behind a fabricated activation receipt, and "
                "it is excluded from Release. 10.1 wants a signed Initial Model Bundle whose "
                "artifact digests ModelBundleActivator measured against a verified manifest, "
                "and none exists. The absence of any activation receipt or signed model manifest "
                "beside these bytes — see bundleLikeFiles — is what distinguishes the two."
            ),
        )
        report.say(
            f"  {composition_name}: bundled Core ML artifacts {artifacts}; development model, "
            "not an approved Initial Model Bundle (observation)"
        )
    report.facts[f"{composition_name}.bundledCoreMLArtifacts"] = artifacts

    # The negative half: no download API from the module that would perform an update.
    download_symbols = [
        "URLSession",
        "NSURLSession",
        "URLRequest",
        "NSURLDownload",
        "NSBundleResourceRequest",
        "BGAppRefreshTask",
        "BGProcessingTask",
    ]
    model_objects = [
        path
        for path in compiled_objects(build_root)
        if (object_owner(path) or "") == "DefAIkeModelBundle"
    ]
    report.require(
        bool(model_objects),
        f"{composition_name}: no DefAIkeModelBundle objects were found, so no model-update "
        "reference could have been detected",
    )
    for path in model_objects:
        try:
            undefined = undefined_symbols(path)
        except RuntimeError as error:
            report.fail(f"{composition_name}: {path.name}: nm failed: {error}")
            continue
        for symbol in download_symbols:
            report.require(
                symbol not in undefined,
                f"model-update: {composition_name}: DefAIkeModelBundle/{path.name} references "
                f"{symbol}; Remote Model Updates stay disabled and no discovery or download "
                "request is issued (Requirements 10.19, 10.21)",
            )
    report.facts[f"{composition_name}.modelBundleObjectsScanned"] = len(model_objects)
    report.say(
        f"  {composition_name}: {len(model_objects)} DefAIkeModelBundle objects, "
        f"0 of {len(download_symbols)} download surfaces referenced"
    )


# MARK: - Layer 6: the vendor static archive

def check_vendor_network_stack(build_root: pathlib.Path, report: Report) -> None:
    """Inventory the network stack inside the linked `C2PAC` static archive.

    12.3 recorded `URLSession` inside `C2PA.o` — the thin Swift wrapper — as a
    `third-party-symbol-reference` observation. The native library the wrapper calls is a
    separate and much larger fact: `C2PAC.xcframework`'s simulator slice is a fat static archive
    of roughly 420 MB, Xcode links it statically, and the 33 KB stub it embeds at
    `DefAIke.app/Frameworks/C2PAC.framework/C2PAC` exports no symbols and carries a build-time
    temporary path as its `LC_ID_DYLIB` install name. So the stub tells a reader nothing, and the
    only way to know what was linked is to read the archive.

    Recorded as a Provenance Feasibility Gate security-review input, never as a violation. The
    inventory is a fact about the reviewed validator, and this task's job is to state it
    accurately rather than to decide what the gate should conclude.
    """
    checkouts = build_root / "SourcePackages" / "artifacts" / "c2pa-swift" / "C2PAC"
    candidates = sorted(checkouts.rglob("C2PAC.framework/C2PAC")) if checkouts.is_dir() else []
    simulator = [path for path in candidates if "simulator" in str(path)]
    if not simulator:
        report.observe(
            "vendor-network-stack-unmeasured",
            requirements=["9.2", "9.3", "10.21"],
            searched=str(checkouts),
            note=(
                "The C2PAC simulator slice was not found under this build's SourcePackages, so "
                "the vendor archive's contents were not inventoried in this run."
            ),
        )
        report.say("  vendor archive: not found under SourcePackages; not inventoried")
        return

    archive = simulator[0]
    size = archive.stat().st_size
    try:
        # `nm` over a fat `ar` archive reports one slice at a time, so the slice is thinned out
        # first. `lipo -thin` rather than `-extract`, because the output has to be an archive
        # `nm` will walk member by member.
        with tempfile.TemporaryDirectory(prefix="t125-vendor-") as temporary:
            thin = pathlib.Path(temporary) / "C2PAC-arm64.a"
            run_tool(["xcrun", "lipo", "-thin", "arm64", str(archive), "-output", str(thin)])
            defined, unreadable = run_tolerating_partial_failure(
                ["xcrun", "nm", "-gU", str(thin)]
            )
    except RuntimeError as error:
        report.observe(
            "vendor-network-stack-unmeasured",
            requirements=["9.2", "9.3", "10.21"],
            archive=str(archive),
            error=str(error)[:400],
        )
        report.say(f"  vendor archive: inventory failed: {str(error)[:200]}")
        return

    crates = {
        crate: len(re.findall(re.escape(crate), defined)) for crate in VENDOR_NETWORK_CRATES
    }
    present = {crate: count for crate, count in crates.items() if count}
    members = len(re.findall(r"\.o:$", defined, re.MULTILINE))
    report.observe(
        "vendor-network-stack-inventory",
        requirements=["6.8", "9.2", "9.3", "10.19", "10.21"],
        archive=str(archive.relative_to(build_root)),
        archiveSizeBytes=size,
        archiveMembers=members,
        globallyDefinedSymbols=len(defined.splitlines()),
        membersUnreadableByThisToolchain=unreadable,
        networkCrateSymbolCounts=present,
        embeddedStub=(
            "DefAIke.app/Frameworks/C2PAC.framework/C2PAC exports no symbols and its "
            "LC_ID_DYLIB install name is a build-time temporary path; the code is linked "
            "statically, so the stub reveals nothing about what was linked"
        ),
        lowerBound=(
            "Every count here is a LOWER BOUND. This toolchain cannot read the bitcode of "
            f"{unreadable} archive members produced by LLVM22.1.2-rust-1.96.0-stable, so their "
            "symbols are absent from the inventory. The finding is that the stack is present, "
            "not how much of it there is."
        ),
        note=(
            "A Provenance Feasibility Gate security-review input, not a violation. The reviewed "
            "validator's native library statically contributes an HTTP client, an HTTP/2 "
            "implementation, a TLS implementation, a root-certificate store, and an async "
            "runtime to the provenance-enabled archive. Requirements 6.8, 9.3, and 10.21 are "
            "therefore satisfied in that composition by runtime configuration "
            "(C2PALibraryReader.applyOfflineSettings) rather than by absence. Removing the "
            "capability means removing the reviewed validator."
        ),
    )
    report.facts["vendorNetworkCrateSymbolCounts"] = present
    report.facts["vendorArchiveSizeBytes"] = size
    report.say(
        f"  vendor archive: {size} bytes, {members} readable members, "
        f"{unreadable} member(s) this toolchain cannot read, "
        f"network crates {json.dumps(present, sort_keys=True)} (observation)"
    )


# MARK: - Drivers

def run_static_checks(root: pathlib.Path, report: Report) -> None:
    report.say("Result persistence and export, in production sources")
    check_result_persistence_sources(root, report)
    report.say("Result persistence, export, and update declarations")
    check_result_persistence_declarations(root, report)


def run_product_checks(build: pathlib.Path, report: Report) -> None:
    products = build / "Build" / "Products" / "Debug-iphonesimulator"

    report.say("Per-compiled-object attribution")
    check_object_attribution(APP.name, build, report)

    report.say("Network capability split")
    measured = measure_image_symbols(APP.name, products, report)
    check_network_capability_split(measured, build, report)

    report.say("Endpoint inventory")
    hosts = check_endpoints(APP.name, products, report)
    check_share_extension_has_no_endpoint(hosts, report)

    report.say("Model delivery")
    check_model_delivery(APP.name, build, report)

    report.say("Vendor static archive")
    check_vendor_network_stack(build, report)


# MARK: - Non-vacuity self-tests

# Each entry plants one real violation in a copy of the repository and names the substring the
# check that must fire will produce. A check nobody has seen fail is a check nobody has seen
# work: 12.2 measured a scanner that reported nothing because its patterns never matched, and
# 12.3 measured a `\b`-anchored symbol scan that was silently vacuous for the same reason.
SELF_TESTS: list[tuple[str, str]] = [
    ("pasteboard-write", "names UIPasteboard"),
    ("share-sheet", "names UIActivityViewController"),
    ("swiftui-sharelink", "names ShareLink"),
    ("core-data-store", "imports CoreData"),
    ("user-defaults", "names UserDefaults"),
    ("photo-library-write", "names PHPhotoLibrary"),
    ("persistent-directory", "names the persistent search-path domain documentDirectory"),
    # The direction split above is itself checked: an outbound registration on the very type the
    # extension legitimately receives must fire, and the ingest sites must stay silent. Without
    # this probe, narrowing the list to survive the four `UniformTypeIdentifiers` and five
    # `NSItemProvider`/`Transferable` false positives could have narrowed it to nothing.
    ("item-provider-export", "names registerFileRepresentation"),
    ("transferable-export", "names exportedContentType"),
    ("document-browser-key", "Info.plist declares ['UISupportsDocumentBrowser']"),
    ("model-update-key", "Info.plist declares ['NSAppTransportSecurity']"),
    ("icloud-entitlement", "declares ['com.apple.developer.ubiquity-container-identifiers']"),
]


def plant(name: str, root: pathlib.Path) -> None:
    """Introduce one real violation into a copied tree."""
    domain = root / "DefAIkePackage" / "Sources" / "DefAIkeDomain"
    planted = domain / "PlantedPersistenceViolation.swift"
    info = root / "DefAIkeApp" / "Support" / "Info.plist"
    entitlements = root / "DefAIkeApp" / "Support" / "DefAIkeApp.entitlements"

    def rewrite(path: pathlib.Path, old: str, new: str) -> None:
        text = path.read_text(encoding="utf-8")
        assert old in text, f"self-test {name}: {path.name} does not contain {old!r}"
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    sources = {
        "pasteboard-write": "func planted() { UIPasteboard.general.string = report }\n",
        "share-sheet": "func planted() { _ = UIActivityViewController(activityItems: []) }\n",
        "swiftui-sharelink": "func planted() { _ = ShareLink(item: report) }\n",
        "core-data-store": "import CoreData\n",
        "user-defaults": "func planted() { UserDefaults.standard.set(1, forKey: \"k\") }\n",
        "photo-library-write": "func planted() { PHPhotoLibrary.shared() }\n",
        "persistent-directory": (
            "func planted() { _ = FileManager.default.urls(for: .documentDirectory) }\n"
        ),
        "item-provider-export": (
            "func planted(_ p: NSItemProvider) { p.registerFileRepresentation() }\n"
        ),
        "transferable-export": (
            "func planted() { _ = FileRepresentation(exportedContentType: .json) }\n"
        ),
    }
    if name in sources:
        planted.write_text(sources[name], encoding="utf-8")
    elif name == "document-browser-key":
        rewrite(info, "<dict>", "<dict>\n\t<key>UISupportsDocumentBrowser</key>\n\t<true/>")
    elif name == "model-update-key":
        rewrite(info, "<dict>", "<dict>\n\t<key>NSAppTransportSecurity</key>\n\t<dict/>")
    elif name == "icloud-entitlement":
        rewrite(
            entitlements,
            "<dict>",
            "<dict>\n\t<key>com.apple.developer.ubiquity-container-identifiers</key>\n\t<array/>",
        )
    else:  # pragma: no cover - the table and this function are edited together.
        raise AssertionError(f"unknown self-test {name}")


def self_test() -> int:
    """Prove every static check can fail, by planting one real violation at a time."""
    print("Non-vacuity self-test (static)")
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
        with tempfile.TemporaryDirectory(prefix="t125-selftest-") as temporary:
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
            matched = [finding for finding in report.findings if expected in finding]
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


def self_test_products(build: pathlib.Path) -> int:
    """Prove every archive check can fail, by pointing it at things known to be present.

    A planted violation cannot be used here: producing an archive that references a pasteboard
    would mean building a different project. So each probe substitutes a vocabulary for one the
    archive is known to contain, and requires the finding. That settles the question a passing
    run leaves open — whether the scan can see anything at all.
    """
    global NETWORK_SYMBOLS, PERSISTENCE_EXPORT_SYMBOLS  # noqa: PLW0603 - restored in `finally`
    print("Non-vacuity self-test (archives)")
    expectations: list[tuple[str, str, int]] = []

    products = build / "Build" / "Products" / "Debug-iphonesimulator"

    saved_network = NETWORK_SYMBOLS
    saved_persistence = PERSISTENCE_EXPORT_SYMBOLS
    try:
        # 1. Object attribution, against a symbol every compiled Swift object references.
        NETWORK_SYMBOLS = ["swift_release"]
        PERSISTENCE_EXPORT_SYMBOLS = []
        report = Report(quiet=True)
        check_object_attribution(APP.name, build, report)
        expectations.append(
            (
                "object attribution sees a real symbol",
                "references the network symbol swift_release",
                len([f for f in report.findings if "swift_release" in f]),
            )
        )

        # 2. The persistence vocabulary, over the same objects.
        NETWORK_SYMBOLS = []
        PERSISTENCE_EXPORT_SYMBOLS = ["swift_retain"]
        report = Report(quiet=True)
        check_object_attribution(APP.name, build, report)
        expectations.append(
            (
                "persistence vocabulary sees a real symbol",
                "references swift_retain",
                len([f for f in report.findings if "swift_retain" in f]),
            )
        )
    finally:
        NETWORK_SYMBOLS = saved_network
        PERSISTENCE_EXPORT_SYMBOLS = saved_persistence

    # 3. The Share Extension network assertion, held to the application's images.
    #
    # The probe relabels every image as an extension image, so the assertion that used to be
    # aimed at a validator-free archive is aimed at the one that links the validator. It has to
    # fire, or the extension's zero is a scan that measures nothing.
    report = Report(quiet=True)
    measured = measure_image_symbols(APP.name, products, report)
    relabelled = {
        f"{EXTENSION_PREFIX}{image}": symbols for image, symbols in measured.items()
    }
    probe = Report(quiet=True)
    check_network_capability_split(relabelled, build, probe)
    expectations.append(
        (
            "the Share Extension network assertion refuses the application's images",
            "the Share Extension references",
            len([f for f in probe.findings if "the Share Extension references" in f]),
        )
    )

    # 4. The endpoint assertion, held to the application's strings, the same way.
    probe = Report(quiet=True)
    hosts = check_endpoints(APP.name, products, probe)
    endpoint_probe = Report(quiet=True)
    check_share_extension_has_no_endpoint(
        {f"{EXTENSION_PREFIX}{image}": count for image, count in hosts.items()},
        endpoint_probe,
    )
    expectations.append(
        (
            "the endpoint assertion refuses the application's strings",
            "contains URL-like strings",
            len([f for f in endpoint_probe.findings if "contains URL-like strings" in f]),
        )
    )

    # 5. Archive attribution: the archive must refuse a name that is not its own. `pixel-only`
    # is the retired composition, so this also fails loudly if that name is reintroduced.
    probe = Report(quiet=True)
    COMPOSITIONS.append(
        _CAPABILITY_CHECK.Composition(
            name="pixel-only",
            bundle_identifier="dev.defaike.app.retired",
            product="DefAIkePixelOnly",
            source_directory="PixelOnly",
            links_validator=False,
        )
    )
    try:
        measure_image_symbols("pixel-only", products, probe)
    finally:
        COMPOSITIONS.pop()
    expectations.append(
        (
            "the archive refuses the name pixel-only",
            "the wrong build was supplied",
            len([f for f in probe.findings if "the wrong build was supplied" in f]),
        )
    )

    # 6. Model-delivery attribution. The probe is inverted relative to the others: rather than
    # requiring a finding, it requires the *absence* of the "no DefAIkeModelBundle objects"
    # finding, because that finding is precisely what a vacuous model-update scan would produce.
    report = Report(quiet=True)
    check_model_delivery(APP.name, build, report)
    expectations.append(
        (
            "model-delivery scan found DefAIkeModelBundle objects to examine",
            "",
            0 if any("no DefAIkeModelBundle objects" in f for f in report.findings) else 1,
        )
    )

    failures = 0
    for description, expected, count in expectations:
        if count:
            print(f"  PASS {description} ({count} finding(s))")
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
        "--build",
        type=pathlib.Path,
        help="the -derivedDataPath root of a DefAIkeApp build",
    )
    parser.add_argument("--json", type=pathlib.Path, help="write findings and facts to a file")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="prove every static check can fail, by planting one violation at a time",
    )
    parser.add_argument(
        "--self-test-products",
        action="store_true",
        help="prove every archive check can fail, using vocabularies known to be present",
    )
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()

    builds: dict[str, pathlib.Path | None] = {APP.name: arguments.build}
    complete = arguments.build is not None

    if arguments.self_test_products:
        if not complete:
            print("error: --self-test-products needs --build", file=sys.stderr)
            return 2
        return self_test_products(arguments.build)

    report = Report()

    print("Delegated audits (tasks 12.2 and 12.3)")
    delegate_to_existing_audits(builds, report)
    run_static_checks(IOS, report)

    if complete:
        run_product_checks(arguments.build, report)
    else:
        print("Built archive")
        print("  skipped: pass --build to inspect the built archive")

    if report.observations:
        print()
        print("Observations (measured, not violations)")
        for observation in report.observations:
            if observation["kind"] == "delegated-capability-observation":
                continue
            print("  " + json.dumps(observation, sort_keys=True))
        delegated = [
            o for o in report.observations if o["kind"] == "delegated-capability-observation"
        ]
        if delegated:
            print(f"  ... plus {len(delegated)} delegated observation(s) from 12.3, in --json")

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
