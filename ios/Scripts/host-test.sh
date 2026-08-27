#!/usr/bin/env bash
#
# Builds every DefAIkePackage composition product and runs the package test
# suite on the development host.
#
# Host results are development checks only. They never satisfy a physical-device
# release gate, and they do not prove iOS-target compilation: that requires Xcode
# and is covered by build-ios.sh.
#
# Swift Testing ships as a framework in the Command Line Tools install without the
# search and runtime paths SwiftPM passes when Xcode is active, so those paths are
# supplied explicitly when Xcode is absent.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../DefAIkePackage" && pwd)"
cd "${PACKAGE_DIR}"

TESTING_FLAGS=()
if ! xcodebuild -version >/dev/null 2>&1; then
    DEVELOPER_DIR_PATH="$(xcode-select -p)"
    FRAMEWORKS="${DEVELOPER_DIR_PATH}/Library/Developer/Frameworks"
    INTEROP_LIB="${DEVELOPER_DIR_PATH}/Library/Developer/usr/lib"

    if [[ -d "${FRAMEWORKS}/Testing.framework" ]]; then
        TESTING_FLAGS=(
            -Xswiftc -F -Xswiftc "${FRAMEWORKS}"
            -Xlinker -F -Xlinker "${FRAMEWORKS}"
            -Xlinker -rpath -Xlinker "${FRAMEWORKS}"
            -Xlinker -rpath -Xlinker "${INTEROP_LIB}"
        )
        echo "note: Xcode is not active; using Swift Testing from ${FRAMEWORKS}"
    else
        echo "error: Swift Testing framework not found under ${FRAMEWORKS}" >&2
        echo "       Install Xcode, or a toolchain that provides Testing.framework." >&2
        exit 1
    fi
fi

for product in \
    DefAIkePixelOnly \
    DefAIkePixelPlusProvenance \
    DefAIkeShareExtensionKit \
    DefAIkeReleaseValidation
do
    echo "==> swift build --product ${product}"
    swift build --product "${product}"
done

echo "==> swift test"
swift test ${TESTING_FLAGS[@]+"${TESTING_FLAGS[@]}"}
