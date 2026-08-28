#!/usr/bin/env bash
#
# Generates ios/DefAIke.xcodeproj from ios/project.yml.
#
# The project file is generated rather than committed, so the target graph,
# build configurations, capability compositions, and signing-free defaults stay
# reviewable in one declarative spec.
#
# Requires XcodeGen. Install one of:
#   brew install xcodegen
#   mint install yonaskolb/XcodeGen

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="${IOS_DIR}/project.yml"

if [[ ! -f "${SPEC}" ]]; then
    echo "error: missing project spec at ${SPEC}" >&2
    exit 1
fi

# Local, uncommitted build settings: the developer's Apple team identifier and an
# optional bundle-identifier prefix. `project.yml` references this file
# unconditionally, so it has to exist before generation; seeding it from the
# committed example keeps a fresh clone generating without any manual step.
#
# Never overwritten. A developer's team identifier survives every regeneration.
LOCAL_CONFIG="${IOS_DIR}/Local.xcconfig"
if [[ ! -f "${LOCAL_CONFIG}" ]]; then
    cp "${IOS_DIR}/Local.xcconfig.example" "${LOCAL_CONFIG}"
    echo "note: created ios/Local.xcconfig from the example; set"
    echo "      DEFAIKE_LOCAL_DEVELOPMENT_TEAM there to build for a physical device"
fi

if command -v xcodegen >/dev/null 2>&1; then
    GENERATOR=(xcodegen)
elif command -v mint >/dev/null 2>&1; then
    GENERATOR=(mint run yonaskolb/XcodeGen xcodegen)
else
    cat >&2 <<'MSG'
error: XcodeGen not found.

Install it with one of:
  brew install xcodegen
  mint install yonaskolb/XcodeGen
MSG
    exit 1
fi

"${GENERATOR[@]}" generate \
    --spec "${SPEC}" \
    --project "${IOS_DIR}" \
    --use-cache \
    --cache-path "${IOS_DIR}/.xcodegen-cache"

echo "Generated ${IOS_DIR}/DefAIke.xcodeproj"

if ! xcodebuild -version >/dev/null 2>&1; then
    cat >&2 <<'MSG'

warning: Xcode is not the active developer directory, so the iOS targets cannot
be compiled here. Install Xcode and run:

  sudo xcode-select --switch /Applications/Xcode.app

Host-only verification (module graph, unit and property tests) is available with:

  ios/Scripts/host-test.sh
MSG
fi

echo "Open ${IOS_DIR}/DefAIke.xcworkspace"
