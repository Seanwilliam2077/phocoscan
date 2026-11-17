#!/bin/bash
# Run on a Mac with Xcode 16.3+ selected. No signing credentials are embedded.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo 'iOS compilation requires macOS + Xcode. Windows can run the Node backend.' >&2
  exit 1
fi
xcodebuild -version
if command -v node >/dev/null 2>&1; then node scripts/generate-xcode-project.mjs; fi
xcodebuild -resolvePackageDependencies -project ios/PocketWorld.xcodeproj -scheme PocketWorld
xcodebuild -project ios/PocketWorld.xcodeproj -scheme PocketWorld \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/DerivedData ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
echo 'Simulator build succeeded. Next: open Xcode, set Team/unique Bundle ID and Run on iPhone.'
echo 'Camera, GPU performance, permissions, signing, and real scans still require physical-device validation.'

