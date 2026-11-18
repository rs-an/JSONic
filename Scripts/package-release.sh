#!/bin/zsh
set -euo pipefail
umask 022

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
RELEASE_DIR="$PROJECT_DIR/releases/JSONic-$VERSION-installer"
ARTIFACT_NAME="JSONic-$VERSION-universal-installer"

if [[ -e "$RELEASE_DIR" ]]; then
    print -u2 "Release already exists: $RELEASE_DIR (nothing overwritten)."
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jsonic-release.XXXXXX")"
IMAGE_MOUNTED=0
cleanup() {
    if [[ "$IMAGE_MOUNTED" == 1 ]]; then
        if ! hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
            print -u2 "Installer is still mounted; temporary folder retained: $WORK_DIR"
            return
        fi
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
IMAGE_DIR="$WORK_DIR/image"
APP_DIR="$IMAGE_DIR/JSONic.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT="$SDK_PATH"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/distribution-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/distribution-swift-cache"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
print "Building a clean universal app. Temporary output: $WORK_DIR"
DMG_TOOLS="$PROJECT_DIR/.build/dmg-tools"
if ! PYTHONPATH="$DMG_TOOLS" python3 -c 'import ds_store, mac_alias' 2>/dev/null; then
    python3 -m pip install --target "$DMG_TOOLS" ds-store==1.3.1 mac-alias==2.2.2
fi

for architecture in arm64 x86_64; do
    build_args=(
        --package-path "$PROJECT_DIR"
        --scratch-path "$PROJECT_DIR/.build/distribution-$architecture"
        --disable-sandbox -c release -j 1
        --triple "$architecture-apple-macosx13.0"
        -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=/JSONic"
        -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=/JSONic"
        -Xswiftc -file-compilation-dir -Xswiftc /JSONic
        -Xcc "-ffile-prefix-map=$PROJECT_DIR=/JSONic"
        -Xcc "-fdebug-prefix-map=$PROJECT_DIR=/JSONic"
    )
    swift build "${build_args[@]}" --product JSONic
    bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
    cp -X "$bin_dir/JSONic" "$WORK_DIR/JSONic-$architecture"
done

xcrun lipo -create "$WORK_DIR/JSONic-arm64" "$WORK_DIR/JSONic-x86_64" \
    -output "$APP_DIR/Contents/MacOS/JSONic"
xcrun strip -S "$APP_DIR/Contents/MacOS/JSONic"
chmod 755 "$APP_DIR/Contents/MacOS/JSONic"
cp -X "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp -X "$PROJECT_DIR/Assets/AppIcon.png" "$APP_DIR/Contents/Resources/AppIcon.png"

cp -X "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -X "$PROJECT_DIR/Vendor/ZIPFoundation/Resources/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/"
cp -X "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
mkdir -p "$APP_DIR/Contents/Resources/ThirdParty"
cp -X "$PROJECT_DIR/ThirdParty/"* "$APP_DIR/Contents/Resources/ThirdParty/"

# No developer profile is available locally. Do not pretend ad-hoc signing is
# Developer ID signing or notarization. This package needs a first-run exception.
codesign --force --options runtime --timestamp=none --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
xcrun lipo "$APP_DIR/Contents/MacOS/JSONic" -verify_arch arm64 x86_64
if LC_ALL=C /usr/bin/grep -a -q -F "$PROJECT_DIR" "$APP_DIR/Contents/MacOS/JSONic"; then
    print -u2 "Developer workspace path leaked into the release binary."
    exit 1
fi

# Exact allowlist: build products only, never Application Support, preferences,
# Keychain items, working folders, screenshots, or application data.
while IFS= read -r bundle_file; do
    relative_file="${bundle_file#"$APP_DIR/"}"
    case "$relative_file" in
        Contents/Resources/LICENSE|Contents/Info.plist|Contents/MacOS/JSONic|Contents/Resources/AppIcon.png|\
        Contents/Resources/AppIcon.icns|Contents/Resources/PrivacyInfo.xcprivacy|\
        Contents/Resources/ThirdParty/SOURCES.md|Contents/Resources/ThirdParty/ZIPFoundation-LICENSE.txt|\
        Contents/Resources/ThirdParty/libxls-LICENSE.txt|Contents/Resources/ThirdParty/pii-guard-LICENSE.txt|\
        Contents/Resources/ThirdParty/pii-guard-NOTICE.txt|Contents/Resources/ThirdParty/presidio-LICENSE.txt|\
        Contents/_CodeSignature/CodeResources) ;;
        *) print -u2 "Unexpected file in app: $relative_file"; exit 1 ;;
    esac
done < <(find "$APP_DIR" -type f)
if [[ -n "$(find "$APP_DIR" -type l)" ]]; then
    print -u2 "Unexpected symlink inside app."
    exit 1
fi

cp -X "$PROJECT_DIR/distribution/INSTALL.txt" "$IMAGE_DIR/INSTALL.txt"
ln -s /Applications "$IMAGE_DIR/Applications"

ditto -c -k --norsrc --noextattr --noacl \
    "$IMAGE_DIR" "$WORK_DIR/$ARTIFACT_NAME.zip"
# Instructions remain in the ZIP and alongside the DMG, not in its main window.
mkdir -p "$WORK_DIR/dmg/.background"
ditto --noextattr --noacl "$APP_DIR" "$WORK_DIR/dmg/JSONic.app"
ln -s /Applications "$WORK_DIR/dmg/Программы"
swift "$SCRIPT_DIR/dmg-background.swift" "$WORK_DIR/dmg/.background/installer.png"
hdiutil create -volname JSONic -srcfolder "$WORK_DIR/dmg" -fs HFS+ -format UDRW \
    "$WORK_DIR/installer-rw.dmg"
MOUNT_DIR="$WORK_DIR/mounted"
mkdir -p "$MOUNT_DIR"
IMAGE_MOUNTED=1
hdiutil attach -readwrite -noautoopen -nobrowse -mountpoint "$MOUNT_DIR" "$WORK_DIR/installer-rw.dmg"
PYTHONPATH="$DMG_TOOLS" python3 "$SCRIPT_DIR/style-dmg.py" "$MOUNT_DIR"
sync
if [[ ! -s "$MOUNT_DIR/.DS_Store" ]]; then
    print -u2 "Installer layout was not saved."
    exit 1
fi
hdiutil detach "$MOUNT_DIR"
IMAGE_MOUNTED=0
hdiutil convert "$WORK_DIR/installer-rw.dmg" -format UDZO -o "$WORK_DIR/$ARTIFACT_NAME.dmg"
hdiutil verify "$WORK_DIR/$ARTIFACT_NAME.dmg"

mkdir -p "$RELEASE_DIR"
cp -X "$WORK_DIR/$ARTIFACT_NAME.dmg" "$WORK_DIR/$ARTIFACT_NAME.zip" "$RELEASE_DIR/"
cp -X "$PROJECT_DIR/distribution/INSTALL.txt" "$RELEASE_DIR/INSTALL.txt"
(
    cd "$RELEASE_DIR"
    shasum -a 256 "$ARTIFACT_NAME.dmg" "$ARTIFACT_NAME.zip" > SHA256SUMS.txt
)
cp -X "$PROJECT_DIR/distribution/RELEASE_NOTES.md" "$RELEASE_DIR/RELEASE_NOTES.md"
print "Release ready (ad-hoc signed, NOT notarized): $RELEASE_DIR"
