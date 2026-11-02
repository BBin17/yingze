#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$project_dir/dist/影择.app"
dmg_path="$project_dir/dist/影择-arm64.dmg"
staging_dir="$project_dir/dist/dmg-staging"

"$project_dir/Scripts/build-app.sh"

rm -rf "$staging_dir"
mkdir -p "$staging_dir"
cp -R "$app_path" "$staging_dir/影择.app"
ln -s /Applications "$staging_dir/Applications"
rm -f "$dmg_path"

hdiutil create \
    -volname "影择" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

rm -rf "$staging_dir"
echo "$dmg_path"
