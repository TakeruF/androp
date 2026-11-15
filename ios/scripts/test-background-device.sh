#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
if (( $# != 1 )); then
  print -u2 'Usage: scripts/test-background-device.sh <unlocked-device-udid>'
  exit 2
fi
ANDROP_BACKGROUND_DEVICE="$1"
: "${ANDROP_DEVELOPMENT_TEAM:?Set ANDROP_DEVELOPMENT_TEAM to your Apple development team}"
cd "${0:A:h:h}"
ANDROP_BACKGROUND_RESULT="build/BackgroundDevice-$(uuidgen).xcresult"
function restore_after_verification() {
  local androp_verification_exit_code=$?
  trap - EXIT
  xcrun devicectl device process launch --device "$ANDROP_BACKGROUND_DEVICE" --terminate-existing com.takeruf.androp.ios || true
  xcrun devicectl device uninstall app --device "$ANDROP_BACKGROUND_DEVICE" com.takeruf.androp.sharefixture || true
  xcrun devicectl device uninstall app --device "$ANDROP_BACKGROUND_DEVICE" com.takeruf.androp.ios.uitests.xctrunner || true
  exit "$androp_verification_exit_code"
}
trap restore_after_verification EXIT
xcodegen generate
xcodebuild -project anDrop.xcodeproj -scheme anDropShareFixture \
  -destination "id=${ANDROP_BACKGROUND_DEVICE}" -derivedDataPath build/BackgroundDevice \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$ANDROP_DEVELOPMENT_TEAM" build
xcrun devicectl device install app --device "$ANDROP_BACKGROUND_DEVICE" \
  build/BackgroundDevice/Build/Products/Debug-iphoneos/anDropShareFixture.app
xcodebuild -project anDrop.xcodeproj -scheme anDrop \
  -destination "id=${ANDROP_BACKGROUND_DEVICE}" -parallel-testing-enabled NO \
  -derivedDataPath build/BackgroundDevice -allowProvisioningUpdates DEVELOPMENT_TEAM="$ANDROP_DEVELOPMENT_TEAM" \
  -resultBundlePath "$ANDROP_BACKGROUND_RESULT" \
  -only-testing:anDropUITests/BackgroundTransferTests test
