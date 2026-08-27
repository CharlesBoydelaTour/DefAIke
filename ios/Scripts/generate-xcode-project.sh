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
