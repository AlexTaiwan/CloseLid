#!/bin/sh
# Builds build/CloseLid.app (Release, ad-hoc signed). Requires xcodegen and Xcode 26.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -scheme CloseLid -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  build -quiet
rm -rf build/CloseLid.app
cp -R build/DerivedData/Build/Products/Release/CloseLid.app build/CloseLid.app
codesign --force --sign - build/CloseLid.app
echo "Built build/CloseLid.app"
