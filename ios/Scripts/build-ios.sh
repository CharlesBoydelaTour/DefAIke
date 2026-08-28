#!/usr/bin/env bash
#
# Compiles the application for iOS.
#
# This is the authoritative check that the app, Share Extension, and every linked
# module build against the iOS SDK at the iOS 17.0 minimum. It requires Xcode; the
# Command Line Tools install has no iOS SDK.
#
# Compiling for the simulator is a development check. It is not physical-device
# evidence and cannot satisfy a Device Validation Plan gate.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${IOS_DIR}/DefAIke.xcworkspace"

if ! xcodebuild -version >/dev/null 2>&1; then
    cat >&2 <<'MSG'
error: Xcode is required to compile the iOS targets.

Install Xcode, then:
  sudo xcode-select --switch /Applications/Xcode.app
MSG
    exit 1
fi

if [[ ! -d "${IOS_DIR}/DefAIke.xcodeproj" ]]; then
    echo "note: generating the Xcode project first"
    "${IOS_DIR}/Scripts/generate-xcode-project.sh"
fi

SCHEME=DefAIkeApp

echo "==> xcodebuild build -scheme ${SCHEME}"
xcodebuild build \
    -workspace "${WORKSPACE}" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO
