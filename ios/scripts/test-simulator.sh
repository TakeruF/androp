#!/bin/zsh
set -eu
if (( $# != 1 )); then
  print -u2 'Usage: scripts/test-simulator.sh <simulator-udid>'
  exit 2
fi
ANDROP_TEST_SIMULATOR="$1"
cd "${0:A:h:h}"
xcodegen generate
xcrun simctl bootstatus "$ANDROP_TEST_SIMULATOR" -b
xcodebuild -project anDrop.xcodeproj -scheme anDropShareFixture \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/SimulatorTests build
xcrun simctl install "$ANDROP_TEST_SIMULATOR" \
  build/SimulatorTests/Build/Products/Debug-iphonesimulator/anDropShareFixture.app
xcodebuild -project anDrop.xcodeproj -scheme anDrop \
  -destination "id=${ANDROP_TEST_SIMULATOR}" -parallel-testing-enabled NO \
  -derivedDataPath build/SimulatorTests test
