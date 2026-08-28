#!/usr/bin/env python3
"""Enforce the DefAIke iOS module and target boundaries.

The design fixes boundaries that are easy to erode by adding one convenient
import. This check reads the resolved SwiftPM manifest and the Xcode project
spec and fails closed when any of them is violated:

1. Every module in the design's target table exists.
2. ``DefAIkeDomain`` has no target dependencies.
3. The Share Extension composition cannot reach inference, image-pipeline,
   model-bundle, provenance, application, or release-validation code
   (Extension Execution Policy, Requirement 2.6).
4. The one application composition links ``DefAIkeProvenanceC2PA``, and no retired
   per-capability product or target has come back (Requirements 6.19 and 6.20).
5. ``DefAIkeReleaseValidation`` is absent from every shipping composition.
6. ``swift-property-based`` is exact-pinned and referenced only by test targets
   (never linked into a shipping executable).
6a. ``DefAIkeTestSupport`` belongs to no product, no shipping module depends on
   it, and at least one test target does. Its fakes and call spies must never be
   reachable from a shipping executable, and an unused doubles module would be
   dead code.
7. The declared iOS minimum is 17.0 in both the package and the project spec
   (Requirements 1.2 and 4.2).
8. One app target and one Share Extension target exist, sharing one App Group and
   one bundle-identifier prefix.
9. No Xcode target links a module its role forbids.
10. In the generated project, every target resolves to iPhone-only. Xcode's
    per-target setting presets can silently override a project-level value, so
    the generated result is checked rather than only the spec.

Usage:
    ios/Scripts/check-module-boundaries.py [--require-xcode-project]

PyYAML is required to read the project spec. The repository development
environment provides it (``uv pip install -e ".[docs]"``).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

IOS_DIR = Path(__file__).resolve().parent.parent
PACKAGE_DIR = IOS_DIR / "DefAIkePackage"
PROJECT_SPEC = IOS_DIR / "project.yml"
XCODE_PROJECT = IOS_DIR / "DefAIke.xcodeproj" / "project.pbxproj"

REQUIRED_MODULES = {
    "DefAIkeDomain",
    "DefAIkeSharedTransfer",
    "DefAIkeApplication",
    "DefAIkeImagePipeline",
    "DefAIkeModelBundle",
    "DefAIkeCoreML",
    "DefAIkeProvenanceAPI",
    "DefAIkeProvenanceC2PA",
    "DefAIkePresentation",
    "DefAIkeReleaseValidation",
}

# Nonshipping modules that exist only to support tests. They are regular SwiftPM
# targets so several test targets can share them, but they belong to no product
# and no shipping module may depend on them.
TEST_SUPPORT_MODULES = {
    "DefAIkeTestSupport",
}

# Modules the Share Extension must never be able to reach.
EXTENSION_FORBIDDEN_MODULES = {
    "DefAIkeApplication",
    "DefAIkeImagePipeline",
    "DefAIkeModelBundle",
    "DefAIkeCoreML",
    "DefAIkeProvenanceAPI",
    "DefAIkeProvenanceC2PA",
    "DefAIkePresentation",
    "DefAIkeReleaseValidation",
}

APP_PRODUCT = "DefAIkeAppKit"
EXTENSION_PRODUCT = "DefAIkeShareExtensionKit"
RELEASE_VALIDATION_PRODUCT = "DefAIkeReleaseValidation"

SHIPPING_PRODUCTS = {APP_PRODUCT, EXTENSION_PRODUCT}

# Products that must not exist. The pixel-only application composition was merged into
# the single one, so a manifest that still declares it is a partially reverted merge
# rather than a harmless leftover: two products would mean two capability sets again.
RETIRED_PRODUCTS = {"DefAIkePixelOnly", "DefAIkePixelPlusProvenance"}

PROPERTY_BASED_PACKAGE = "swift-property-based"
PROPERTY_BASED_VERSION = "2.0.0"
PROPERTY_BASED_PRODUCT = "PropertyBased"

REQUIRED_IOS_MINIMUM = "17.0"

APP_TARGET = "DefAIkeApp"
EXTENSION_TARGET = "DefAIkeShareExtension"


class Failures:
    """Collects every violation so one run reports all of them."""

    def __init__(self) -> None:
        self.messages: list[str] = []

    def check(self, condition: bool, message: str) -> None:
        if not condition:
            self.messages.append(message)

    def add(self, message: str) -> None:
        self.messages.append(message)


def load_package() -> dict:
    result = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=PACKAGE_DIR,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(f"error: `swift package dump-package` failed:\n{result.stderr}")
    return json.loads(result.stdout)


def load_project_spec() -> dict:
    try:
        import yaml
    except ModuleNotFoundError:
        sys.exit(
            "error: PyYAML is required to read ios/project.yml.\n"
            '       Install the development environment: uv pip install -e ".[docs]"'
        )
    with PROJECT_SPEC.open(encoding="utf-8") as spec_file:
        return yaml.safe_load(spec_file)


def target_dependency_names(target: dict) -> tuple[set[str], set[str]]:
    """Return (in-package target names, external product names)."""
    by_name: set[str] = set()
    products: set[str] = set()
    for dependency in target.get("dependencies", []):
        if "byName" in dependency:
            by_name.add(dependency["byName"][0])
        if "target" in dependency:
            by_name.add(dependency["target"][0])
        if "product" in dependency:
            products.add(dependency["product"][0])
    return by_name, products


def transitive_modules(root: str, module_dependencies: dict[str, set[str]]) -> set[str]:
    seen: set[str] = set()
    pending = [root]
    while pending:
        current = pending.pop()
        for dependency in module_dependencies.get(current, set()):
            if dependency not in seen:
                seen.add(dependency)
                pending.append(dependency)
    return seen


def check_package(package: dict, failures: Failures) -> None:
    targets = {target["name"]: target for target in package["targets"]}
    regular = {
        name: target
        for name, target in targets.items()
        if target["type"] == "regular"
    }
    tests = {
        name: target for name, target in targets.items() if target["type"] == "test"
    }

    missing = REQUIRED_MODULES - set(regular)
    failures.check(not missing, f"missing design modules: {sorted(missing)}")

    missing_support = TEST_SUPPORT_MODULES - set(regular)
    failures.check(
        not missing_support,
        f"missing test-support modules: {sorted(missing_support)}",
    )

    unexpected = set(regular) - REQUIRED_MODULES - TEST_SUPPORT_MODULES
    failures.check(
        not unexpected,
        f"undeclared shipping modules present: {sorted(unexpected)}. "
        "Add them to REQUIRED_MODULES and to the design target table first, or to "
        "TEST_SUPPORT_MODULES if they are nonshipping test doubles.",
    )

    module_dependencies: dict[str, set[str]] = {}
    for name, target in regular.items():
        by_name, products = target_dependency_names(target)
        module_dependencies[name] = by_name
        failures.check(
            PROPERTY_BASED_PRODUCT not in products,
            f"{name} links {PROPERTY_BASED_PRODUCT}; it is test-only",
        )

    # 6a. No shipping module may depend on a test-support module.
    for name in REQUIRED_MODULES & set(regular):
        leaked_support = transitive_modules(name, module_dependencies) & TEST_SUPPORT_MODULES
        failures.check(
            not leaked_support,
            f"{name} reaches test-support modules {sorted(leaked_support)}; fakes and "
            "call spies are nonshipping",
        )

    # 2. Pure domain core.
    failures.check(
        not module_dependencies.get("DefAIkeDomain", {"unresolved"}),
        "DefAIkeDomain must have no target dependencies, found "
        f"{sorted(module_dependencies.get('DefAIkeDomain', set()))}",
    )

    # Products.
    products = {product["name"]: product for product in package["products"]}
    for required in (APP_PRODUCT, EXTENSION_PRODUCT, RELEASE_VALIDATION_PRODUCT):
        failures.check(required in products, f"missing product {required}")

    def product_closure(name: str) -> set[str]:
        declared = set(products.get(name, {}).get("targets", []))
        closure = set(declared)
        for module in declared:
            closure |= transitive_modules(module, module_dependencies)
        return closure

    # 3. Extension composition stays free of inference and provenance code.
    extension_closure = product_closure(EXTENSION_PRODUCT)
    leaked = extension_closure & EXTENSION_FORBIDDEN_MODULES
    failures.check(
        not leaked,
        f"{EXTENSION_PRODUCT} reaches forbidden modules {sorted(leaked)}; the "
        "Share Extension must run no inference and link no provenance code",
    )

    # 4. The application composition links the validator; nothing else does.
    #
    # This is the declared-closure half of the linkage evidence. The positive claim moved
    # here from an asymmetry between two application products: while a pixel-only product
    # existed, its *absence* of the adapter was the measurement and the provenance
    # product's presence made that absence non-vacuous. One product cannot supply both, so
    # the negative case is now the Share Extension closure asserted in step 3 above, and
    # the retired-product check below keeps the second application product from returning.
    failures.check(
        "DefAIkeProvenanceC2PA" in product_closure(APP_PRODUCT),
        f"{APP_PRODUCT} must link DefAIkeProvenanceC2PA; the application composition is "
        "the one product that compiles Content Credential validation",
    )
    still_declared = sorted(RETIRED_PRODUCTS & set(products))
    failures.check(
        not still_declared,
        f"the manifest still declares {still_declared}; the two capability compositions "
        f"were merged into {APP_PRODUCT}, and a second application product would restore "
        "the two capability sets the merge removed",
    )

    # 5. Release tooling never ships.
    for product in SHIPPING_PRODUCTS:
        failures.check(
            "DefAIkeReleaseValidation" not in product_closure(product),
            f"{product} reaches DefAIkeReleaseValidation; release tooling is "
            "nonshipping",
        )

    # 6a. Test doubles belong to no product at all, shipping or otherwise. Being
    # outside every product is what makes them unlinkable from an executable.
    for product in products:
        leaked_support = product_closure(product) & TEST_SUPPORT_MODULES
        failures.check(
            not leaked_support,
            f"product {product} reaches test-support modules {sorted(leaked_support)}; "
            "they must belong to no product",
        )

    # 6. Exact-pinned, test-only property-based dependency.
    property_based_requirements = [
        dependency
        for dependency in package.get("dependencies", [])
        if PROPERTY_BASED_PACKAGE in json.dumps(dependency)
    ]
    failures.check(
        len(property_based_requirements) == 1,
        f"expected exactly one {PROPERTY_BASED_PACKAGE} dependency, found "
        f"{len(property_based_requirements)}",
    )
    if property_based_requirements:
        serialized = json.dumps(property_based_requirements[0])
        failures.check(
            '"exact"' in serialized and PROPERTY_BASED_VERSION in serialized,
            f"{PROPERTY_BASED_PACKAGE} must be exact-pinned to "
            f"{PROPERTY_BASED_VERSION}, found {serialized}",
        )

    using_property_based = {
        name
        for name, target in tests.items()
        if PROPERTY_BASED_PRODUCT in target_dependency_names(target)[1]
    }
    failures.check(
        bool(using_property_based),
        "no test target depends on PropertyBased; the property-based toolchain "
        "is unwired",
    )

    # 6a. Each test-support module is actually used by a test target.
    test_dependencies: set[str] = set()
    for target in tests.values():
        by_name, _ = target_dependency_names(target)
        test_dependencies |= by_name
        for module in by_name:
            test_dependencies |= transitive_modules(module, module_dependencies)
    unused_support = TEST_SUPPORT_MODULES - test_dependencies
    failures.check(
        not unused_support,
        f"test-support modules {sorted(unused_support)} are unused by any test "
        "target; remove them rather than shipping dead doubles",
    )

    # 7. Declared iOS minimum.
    ios_platform = next(
        (
            platform
            for platform in package.get("platforms", [])
            if platform.get("platformName") == "ios"
        ),
        None,
    )
    failures.check(
        ios_platform is not None and ios_platform.get("version") == REQUIRED_IOS_MINIMUM,
        f"package iOS minimum must be {REQUIRED_IOS_MINIMUM}, found {ios_platform}",
    )


def check_project_spec(spec: dict, failures: Failures) -> None:
    base = spec.get("settings", {}).get("base", {})
    failures.check(
        str(base.get("IPHONEOS_DEPLOYMENT_TARGET")) == REQUIRED_IOS_MINIMUM,
        "project IPHONEOS_DEPLOYMENT_TARGET must be "
        f"{REQUIRED_IOS_MINIMUM}, found {base.get('IPHONEOS_DEPLOYMENT_TARGET')}",
    )
    failures.check(
        str(base.get("TARGETED_DEVICE_FAMILY")) == "1",
        "project TARGETED_DEVICE_FAMILY must be 1 (iPhone only), found "
        f"{base.get('TARGETED_DEVICE_FAMILY')}",
    )
    failures.check(
        str(spec.get("options", {}).get("deploymentTarget", {}).get("iOS"))
        == REQUIRED_IOS_MINIMUM,
        f"project options.deploymentTarget.iOS must be {REQUIRED_IOS_MINIMUM}",
    )

    targets = spec.get("targets", {})

    for name in (APP_TARGET, EXTENSION_TARGET):
        if name not in targets:
            failures.add(f"missing Xcode target {name}")

    # Two targets that must not exist. Their presence means the merged app has been split
    # again, which restores the two capability sets and the pooled-evidence risk
    # Requirement 13.20 forbids.
    for retired in (
        "DefAIkeApp-PixelOnly",
        "DefAIkeApp-PixelPlusProvenance",
        "DefAIkeShareExtension-PixelOnly",
        "DefAIkeShareExtension-PixelPlusProvenance",
    ):
        failures.check(
            retired not in targets,
            f"{retired} still exists; the capability compositions were merged into "
            f"{APP_TARGET}, so a per-composition target would restore two capability sets",
        )

    app = targets.get(APP_TARGET, {})
    app_settings = app.get("settings", {}).get("base", {})
    app_products = {
        dependency.get("product")
        for dependency in app.get("dependencies", [])
        if "product" in dependency
    }
    failures.check(
        app_products == {APP_PRODUCT},
        f"{APP_TARGET} must link only {APP_PRODUCT}, found "
        f"{sorted(product for product in app_products if product)}",
    )
    failures.check(
        app.get("sources", [{}])[0].get("path") == "DefAIkeApp/Shared",
        f"{APP_TARGET} must compile DefAIkeApp/Shared, which is where the one "
        "CompiledCapabilityComposition lives",
    )

    extension_target = targets.get(EXTENSION_TARGET, {})
    extension_settings = extension_target.get("settings", {}).get("base", {})

    app_group = app_settings.get("DEFAIKE_APP_GROUP_ID", "")
    bundle_id = app_settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")
    failures.check(bool(app_group), f"{APP_TARGET} must declare DEFAIKE_APP_GROUP_ID")
    failures.check(bool(bundle_id), f"{APP_TARGET} must declare PRODUCT_BUNDLE_IDENTIFIER")
    failures.check(
        extension_settings.get("DEFAIKE_APP_GROUP_ID") == app_group,
        f"{EXTENSION_TARGET} App Group must match {APP_TARGET}; the handoff slot is the "
        "one namespace both sides address",
    )
    failures.check(
        extension_settings.get("PRODUCT_BUNDLE_IDENTIFIER", "").startswith(
            f"{bundle_id}."
        ),
        f"{EXTENSION_TARGET} bundle identifier must be prefixed by {APP_TARGET}'s",
    )

    # 9. Role-forbidden linkage in the Xcode graph.
    #
    # Read off the targets rather than off shared templates: with one app and one extension
    # the templates were removed, and a template check would silently pass against a spec
    # that no longer has one.
    extension_products = {
        dependency.get("product")
        for dependency in extension_target.get("dependencies", [])
        if "product" in dependency
    }
    failures.check(
        extension_products == {EXTENSION_PRODUCT},
        f"{EXTENSION_TARGET} must link only {EXTENSION_PRODUCT}, found "
        f"{sorted(product for product in extension_products if product)}",
    )
    failures.check(
        RELEASE_VALIDATION_PRODUCT not in app_products,
        "the app target must not link nonshipping release-validation tooling",
    )


def load_generated_project() -> dict:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(XCODE_PROJECT)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        sys.exit(f"error: could not read {XCODE_PROJECT}:\n{result.stderr}")
    return json.loads(result.stdout)["objects"]


def check_generated_project(objects: dict, failures: Failures) -> None:
    """Check effective settings in the generated project.

    Xcode's per-target setting presets are applied after project-level settings,
    so an iPhone-only project value can be overridden to "1,2" by a target
    preset. Only the generated result proves the effective value.
    """
    configuration_lists = {
        identifier: value
        for identifier, value in objects.items()
        if value.get("isa") == "XCConfigurationList"
    }

    checked_targets = 0
    for identifier, value in objects.items():
        if value.get("isa") != "PBXNativeTarget":
            continue
        name = value.get("name", identifier)
        configurations = configuration_lists.get(
            value.get("buildConfigurationList"), {}
        ).get("buildConfigurations", [])
        for configuration_id in configurations:
            configuration = objects.get(configuration_id, {})
            settings = configuration.get("buildSettings", {})
            configuration_name = configuration.get("name", "?")
            family = settings.get("TARGETED_DEVICE_FAMILY")
            if family is None:
                continue
            failures.check(
                str(family) == "1",
                f"{name} ({configuration_name}) resolves "
                f'TARGETED_DEVICE_FAMILY to "{family}"; Requirement 1.1 is '
                "iPhone-only",
            )
            checked_targets += 1

    failures.check(
        checked_targets > 0,
        "no native targets found in the generated project",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--require-xcode-project",
        action="store_true",
        help="fail when the generated Xcode project is absent",
    )
    arguments = parser.parse_args()

    failures = Failures()
    check_package(load_package(), failures)
    check_project_spec(load_project_spec(), failures)

    if XCODE_PROJECT.exists():
        check_generated_project(load_generated_project(), failures)
    elif arguments.require_xcode_project:
        failures.add(
            f"{XCODE_PROJECT} is absent; run ios/Scripts/generate-xcode-project.sh"
        )
    else:
        print(
            "note: generated Xcode project absent, effective-settings checks "
            "skipped. Run ios/Scripts/generate-xcode-project.sh first."
        )

    if failures.messages:
        print("module boundary check FAILED", file=sys.stderr)
        for message in failures.messages:
            print(f"  - {message}", file=sys.stderr)
        return 1

    print("module boundary check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
