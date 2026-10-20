#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="${1:-}"
if [[ -z "$engine_dir" || ! -x "$engine_dir/vectorcraft-cli" ]]; then
  echo 'Usage: bash scripts/build-local.sh /path/to/extracted/vectorcraft-cli-package' >&2
  exit 1
fi
if [[ ! -f "$engine_dir/LICENSE-MIT" || ! -f "$engine_dir/NOTICE" ]]; then
  echo 'Use the complete official engine package, including licence and NOTICE files.' >&2
  exit 1
fi
build_dir="$project_root/build"
app_dir="$project_root/dist/Logo Parcel.app"
mkdir -p "$build_dir/module-cache" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -parse-as-library -module-cache-path "$build_dir/module-cache" "$project_root/src/LogoParcel.swift" -o "$app_dir/Contents/MacOS/LogoParcel"
cp "$project_root/src/packager.py" "$project_root/src/htmlguide.py" "$project_root/resources/branding.json" "$app_dir/Contents/Resources/"
cp "$project_root/resources/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources/engine"
ditto "$engine_dir" "$app_dir/Contents/Resources/engine"
codesign --force --sign - "$app_dir"
codesign --verify "$app_dir"
echo "Local development build: $app_dir"
echo 'This is not a signed/notarised public release. See RELEASE_CHECKLIST.md.'
