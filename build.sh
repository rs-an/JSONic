#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
    echo "Usage: ./build.sh [--check]" >&2; exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
build_args=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release --jobs 2)
swift build "${build_args[@]}" --product JSONic
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
mkdir -p dist
work_dir="$(mktemp -d "$PWD/dist/.build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
app="$work_dir/JSONic.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
cp -X "$bin_dir/JSONic" "$app/Contents/MacOS/JSONic"
cp -X Info.plist "$app/Contents/Info.plist"
cp -X Assets/AppIcon.png Assets/AppIcon.icns "$app/Contents/Resources/"
cp -X Vendor/ZIPFoundation/Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
cp -X ThirdParty/* "$app/Contents/Resources/ThirdParty/"
codesign --force --options runtime --timestamp=none --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ "${1:-}" == "--check" ]]; then
    swift run "${build_args[@]}" JSONicChecks
fi
# Replace only this script's generated bundle, so obsolete resources cannot survive.
rm -rf "$PWD/dist/JSONic.app"
mv "$app" "$PWD/dist/JSONic.app"
printf '%s\n' "$PWD/dist/JSONic.app"
