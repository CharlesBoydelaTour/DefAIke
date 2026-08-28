#!/usr/bin/env python3
"""Verify the Share Extension target contains none of the things it must not.

Task 12.2 requires evidence — not a comment — that the extension target contains no Core ML
model, pixel analyzer, C2PA adapter, evidence coordinator, or unsupported containing-app
launch path. Those are claims about the *declared dependency set*, the extension's *sources*,
and the *built product*, so this script checks all three and reports which of them it could
establish.

    ios/Scripts/check-share-extension-target.py                 # sources + declarations
    ios/Scripts/check-share-extension-target.py --products DIR  # also inspect a built .appex

Why the source scan strips comments and string literals first: the extension's own sources
document `NSExtensionContext.open`, `openURL`, `CoreML`, and every forbidden module by name, in
prose, because explaining why they are absent is the point. A plain grep over those files
reports 16 hits, all of them comments. An earlier unstripped audit of the repository measured
36 such false positives, and a doc comment naming a type once broke a build. So only code is
scanned.

Why `--products` takes a directory: a products directory cannot attribute a binary to a scheme
on its own, so point this at a build's own `-derivedDataPath` products directory rather than at
a shared one that may hold a stale bundle:

    xcodebuild build -workspace ios/DefAIke.xcworkspace \\
        -scheme DefAIkeApp -configuration Debug \\
        -destination 'generic/platform=iOS Simulator' \\
        -derivedDataPath /tmp/defaike CODE_SIGNING_ALLOWED=NO
    ios/Scripts/check-share-extension-target.py \\
        --products /tmp/defaike/Build/Products/Debug-iphonesimulator

This `.appex` carries more of the linkage evidence than it used to. While a pixel-only
application archive existed, *it* was the shipping bundle that provably contained no Content
Credential validator. The two application compositions were merged into one, so the extension is
now the only shipping module closure whose exclusion of the validator can be measured directly.

What this script deliberately does NOT check: the module *closure* as the package manifest
declares it across every transitive edge. `ios/Scripts/check-module-boundaries.py` owns that,
and the two are complementary — that one reads the declared graph, this one reads the shipped
bytes. Nor does it check `canImport` reachability: under Xcode every package module is written
to one shared build-products directory, so the extension's import search path resolves modules
it does not link, and a reachability probe reports five forbidden modules as reachable in a
correct build. Reachability is not linkage, and only the product inspection distinguishes them.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

IOS = pathlib.Path(__file__).resolve().parent.parent
SOURCES = IOS / "DefAIkeShareExtension" / "Sources"
PROJECT_YML = IOS / "project.yml"
PACKAGE_SWIFT = IOS / "DefAIkePackage" / "Package.swift"

# The product the extension targets are allowed to link, and the only one.
ALLOWED_PRODUCT = "DefAIkeShareExtensionKit"

# Modules whose symbols must not appear in the built extension binary. Each is one of the five
# things task 12.2 names, or the module that would carry it.
FORBIDDEN_MODULES = [
    "DefAIkeCoreML",          # pixel analyzer and the Core ML runtime
    "DefAIkeModelBundle",     # the compiled model's verification and location
    "DefAIkeImagePipeline",   # decode, resize, crop, model-input production
    "DefAIkeProvenanceC2PA",  # the Content Credential adapter
    "DefAIkeApplication",     # Analysis Coordinator and Evidence Coordinator
    "DefAIkePresentation",
    "DefAIkeReleaseValidation",
    "DefAIkeTestSupport",
]

# Modules the extension is expected to contain symbols from.
EXPECTED_MODULES = ["DefAIkeDomain", "DefAIkeSharedTransfer", "DefAIkeShareExtension"]

# Apple frameworks an extension that ran a model, decoded an image, or drew a SwiftUI screen
# would have to link. Absence in `otool -L` is the evidence; `canImport` cannot help here,
# because the SDK is always on the search path.
FORBIDDEN_FRAMEWORKS = [
    "CoreML",
    "Vision",
    "Accelerate",
    "ImageIO",
    "CoreGraphics",
    "SwiftUI",
    "PhotosUI",
    "Photos",
    "CoreImage",
]

# Framework surfaces a programmatic containing-app launch would need. `completeRequest` and
# `cancelRequest` are the two sanctioned endings and are deliberately absent from this list.
FORBIDDEN_CODE_PATTERNS: list[tuple[str, str]] = [
    (r"\bopen\s*\(\s*(?:URL|url)\b", "NSExtensionContext.open route into the containing app"),
    (r"\bopenURL\b", "openURL route into the containing app"),
    (r"\bUIApplication\b", "shared-application launch route"),
    (r"\bsharedApplication\b", "shared-application launch route"),
    (r"\bcanOpenURL\b", "URL-scheme probe"),
    (r"\bperformSelector\b", "private-selector workaround"),
    (r"\bNSSelectorFromString\b", "private-selector workaround"),
    (r"\bLSApplicationWorkspace\b", "private launch API"),
    (r"\bimport\s+CoreML\b", "Core ML runtime"),
    (r"\bimport\s+Vision\b", "Vision inference"),
    (r"\bimport\s+Accelerate\b", "signal-processing pipeline"),
    (r"\bimport\s+ImageIO\b", "image decode"),
    (r"\bimport\s+CoreGraphics\b", "image decode"),
    (r"\bimport\s+PhotosUI\b", "Photos route"),
    (r"\bimport\s+SwiftUI\b", "presentation layer"),
    (r"\bMLModel\b", "Core ML model type"),
]
FORBIDDEN_CODE_PATTERNS += [
    (rf"\bimport\s+{module}\b", f"forbidden module {module}") for module in FORBIDDEN_MODULES
]


def strip_swift(source: str) -> str:
    """Blank comments and string literals, preserving line numbers and other characters."""
    out: list[str] = []
    index = 0
    length = len(source)
    depth = 0
    while index < length:
        two = source[index : index + 2]
        if depth > 0:
            if two == "/*":
                depth += 1
                index += 2
            elif two == "*/":
                depth -= 1
                index += 2
            else:
                out.append("\n" if source[index] == "\n" else " ")
                index += 1
            continue
        if two == "/*":
            depth = 1
            index += 2
            continue
        if two == "//":
            while index < length and source[index] != "\n":
                out.append(" ")
                index += 1
            continue
        if source[index] == '"':
            if source[index : index + 3] == '"""':
                end = source.find('"""', index + 3)
                end = length if end == -1 else end + 3
                out.extend("\n" if ch == "\n" else " " for ch in source[index:end])
                index = end
                continue
            index += 1
            out.append(" ")
            while index < length and source[index] != '"':
                if source[index] == "\\":
                    out.append(" ")
                    index += 1
                    if index < length:
                        out.append(" ")
                        index += 1
                    continue
                out.append("\n" if source[index] == "\n" else " ")
                index += 1
            if index < length:
                out.append(" ")
                index += 1
            continue
        out.append(source[index])
        index += 1
    return "".join(out)


def check_sources() -> list[str]:
    """Scan the extension's code for a launch route or an inference surface."""
    findings: list[str] = []
    files = sorted(SOURCES.glob("*.swift"))
    if not files:
        return [f"{SOURCES} contains no Swift sources"]
    for path in files:
        stripped = strip_swift(path.read_text(encoding="utf-8"))
        for number, line in enumerate(stripped.splitlines(), start=1):
            for pattern, why in FORBIDDEN_CODE_PATTERNS:
                if re.search(pattern, line):
                    findings.append(f"{path.name}:{number}: {why}: {line.strip()}")
    print(f"  scanned {len(files)} source files, comments and string literals stripped")
    return findings


def check_declared_dependencies() -> list[str]:
    """Check that the extension target declares only the transfer composition product."""
    findings: list[str] = []

    # Read from the target rather than a shared template. The per-composition templates were
    # removed when the two app targets were merged into one, and a template lookup that finds
    # nothing must be a finding rather than a silent skip.
    yml = PROJECT_YML.read_text(encoding="utf-8")
    match = re.search(
        r"^  DefAIkeShareExtension:\n(?P<body>(?:.*\n)*?)(?=^  \w|^\w)", yml, re.MULTILINE
    )
    if not match:
        findings.append("project.yml: no DefAIkeShareExtension target found")
    else:
        body = match.group("body")
        products = re.findall(r"product:\s*(\S+)", body)
        if products != [ALLOWED_PRODUCT]:
            findings.append(
                f"project.yml DefAIkeShareExtension target links {products}, "
                f"expected exactly ['{ALLOWED_PRODUCT}']"
            )
        for module in FORBIDDEN_MODULES:
            # A forbidden module named in the dependency list, not in a comment.
            for line in body.splitlines():
                code = line.split("#", 1)[0]
                if re.search(rf"\b{module}\b", code):
                    findings.append(
                        f"project.yml DefAIkeShareExtension target references {module}: {line.strip()}"
                    )
        print(f"  project.yml DefAIkeShareExtension target links {products}")

    package = PACKAGE_SWIFT.read_text(encoding="utf-8")
    match = re.search(
        r'name:\s*"' + ALLOWED_PRODUCT + r'",\s*targets:\s*\[(?P<targets>[^\]]*)\]', package
    )
    if not match:
        findings.append(f"Package.swift: no {ALLOWED_PRODUCT} product found")
    else:
        targets = re.findall(r'"([^"]+)"', match.group("targets"))
        if sorted(targets) != sorted(["DefAIkeDomain", "DefAIkeSharedTransfer"]):
            findings.append(
                f"Package.swift {ALLOWED_PRODUCT} exposes {targets}, "
                "expected exactly ['DefAIkeDomain', 'DefAIkeSharedTransfer']"
            )
        print(f"  Package.swift {ALLOWED_PRODUCT} exposes {sorted(targets)}")

    return findings


def run(command: list[str]) -> str:
    return subprocess.run(
        command, check=True, capture_output=True, text=True, encoding="utf-8"
    ).stdout


def check_products(products: pathlib.Path) -> list[str]:
    """Inspect a built .appex: linked frameworks, module symbols, and bundled model artifacts."""
    findings: list[str] = []
    appex = products / "DefAIkeShareExtension.appex"
    if not appex.is_dir():
        return [f"{appex} does not exist; build a scheme with its own -derivedDataPath first"]

    print(
        "  note: this inspection is attributable to a build only because you pointed it at\n"
        "        that build's own derived-data products directory."
    )

    # 1. Model artifacts inside the bundle.
    bundled = [
        path
        for pattern in ("*.mlmodel", "*.mlmodelc", "*.mlpackage", "*.mlmodelc/**")
        for path in appex.rglob(pattern)
    ]
    if bundled:
        findings.append(f"{appex.name} bundles model artifacts: {[p.name for p in bundled]}")
    print(f"  bundled Core ML artifacts: {len(bundled)}")

    # 2. Linked frameworks and module symbols, per Mach-O image in the bundle.
    images = [
        path
        for path in appex.iterdir()
        if path.is_file() and (path.suffix == ".dylib" or path.name == appex.stem)
    ]
    if not images:
        findings.append(f"{appex.name} contains no inspectable Mach-O image")

    for image in sorted(images):
        try:
            linked = run(["xcrun", "otool", "-L", str(image)])
            symbols = run(["xcrun", "nm", str(image)])
            undefined = run(["xcrun", "nm", "-u", str(image)])
        except subprocess.CalledProcessError as error:
            findings.append(f"{image.name}: inspection failed: {error.stderr.strip()}")
            continue

        for framework in FORBIDDEN_FRAMEWORKS:
            if re.search(rf"/{framework}\.framework/", linked):
                findings.append(f"{image.name} links {framework}.framework")

        present = {
            module for module in FORBIDDEN_MODULES if re.search(rf"\b{module}\b", symbols)
        }
        if present:
            findings.append(f"{image.name} contains symbols from {sorted(present)}")
        undefined_forbidden = {
            module for module in FORBIDDEN_MODULES if re.search(rf"\b{module}\b", undefined)
        }
        if undefined_forbidden:
            findings.append(
                f"{image.name} has undefined symbols from {sorted(undefined_forbidden)}"
            )

        found_expected = [
            module for module in EXPECTED_MODULES if re.search(rf"\b{module}\b", symbols)
        ]
        frameworks = sorted(set(re.findall(r"/([A-Za-z]+)\.framework/", linked)))
        print(f"  {image.name}: frameworks {frameworks}")
        print(f"  {image.name}: DefAIke modules present {found_expected}")

    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--products",
        type=pathlib.Path,
        help="A per-scheme build's products directory, for example "
        "/tmp/pixelonly/Build/Products/Debug-iphonesimulator",
    )
    arguments = parser.parse_args()

    findings: list[str] = []

    print("Share Extension sources")
    findings += check_sources()

    print("Declared dependencies")
    findings += check_declared_dependencies()

    if arguments.products:
        print("Built product")
        findings += check_products(arguments.products)
    else:
        print("Built product")
        print("  skipped: pass --products to inspect a built .appex")

    print()
    if findings:
        print(f"FAIL ({len(findings)} finding(s))")
        for finding in findings:
            print("  " + finding)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
