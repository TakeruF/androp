#!/bin/zsh
set -eu
if (( $# != 1 )); then
  print -u2 'Usage: scripts/install-device.sh <device-udid>'
  exit 2
fi
ANDROP_IOS_DEVICE="$1"
: "${ANDROP_DEVELOPMENT_TEAM:?Set ANDROP_DEVELOPMENT_TEAM to your Apple development team}"
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project anDrop.xcodeproj -scheme anDrop \
  -destination "id=${ANDROP_IOS_DEVICE}" -derivedDataPath build/DeviceData \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$ANDROP_DEVELOPMENT_TEAM" build
xcrun devicectl device install app --device "$ANDROP_IOS_DEVICE" \
  build/DeviceData/Build/Products/Debug-iphoneos/anDrop.app
xcrun devicectl device process launch --device "$ANDROP_IOS_DEVICE" com.takeruf.androp.ios
