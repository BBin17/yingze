#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_dir/dist/影择.app"
xcode_configuration="${(C)configuration}"
derived_data="$project_dir/.build/xcode"
built_app="$derived_data/Build/Products/$xcode_configuration/影择.app"

cd "$project_dir"
xcodebuild \
    -project "$project_dir/影择.xcodeproj" \
    -scheme "影择" \
    -configuration "$xcode_configuration" \
    -derivedDataPath "$derived_data" \
    -destination "platform=macOS,arch=arm64" \
    clean build

rm -rf "$app_dir"
ditto "$built_app" "$app_dir"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
