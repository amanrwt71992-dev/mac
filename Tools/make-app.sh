#!/usr/bin/env bash
#
# Assembles Zenith.app from a SwiftPM release build.
#
# SwiftPM produces a bare Mach-O executable, which macOS will not present as an
# application: no Dock icon, no menu bar, no double-click. The bundle layout and
# Info.plist below are what turn one into an app.
#
# The binary is ad-hoc signed (`--sign -`). That is not notarisation and does not
# claim to be: it satisfies arm64's requirement that every executable carry at
# least a valid signature, and nothing more. A user downloading the artifact will
# still have to approve it once in System Settings ▸ Privacy & Security, because
# Gatekeeper has no notarisation ticket to check. Shipping to anyone outside this
# project needs a Developer ID certificate and `notarytool`, which needs an Apple
# Developer account — recorded in docs/06-LEGAL-AND-IP.md rather than faked here.
#
# Usage: Tools/make-app.sh [build-dir] [output-dir] [version]

set -euo pipefail

BUILD_DIR="${1:-.build/release}"
OUT_DIR="${2:-dist}"
VERSION="${3:-0.1.0}"
REVISION="${ZENITH_REVISION:-${GALLEY_REVISION:-unknown}}"

EXECUTABLE="$BUILD_DIR/Zenith"
if [[ ! -f "$EXECUTABLE" ]]; then
  echo "::error::no executable at $EXECUTABLE — did the release build succeed?" >&2
  exit 1
fi

APP="$OUT_DIR/Zenith.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/Zenith"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The bundle identifier is provisional and must change with the final product
# name: it is baked into the user's preferences directory, their Keychain items
# and any sandbox container, so renaming it later orphans all of them.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Zenith</string>
    <key>CFBundleExecutable</key>
    <string>Zenith</string>
    <key>CFBundleIdentifier</key>
    <string>dev.zenith.editor</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Zenith</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>GitRevision</key>
    <string>$REVISION</string>
</dict>
</plist>
PLIST

# A word processor must never be terminated behind the user's back: sudden and
# automatic termination would drop an unsaved document.
/usr/libexec/PlistBuddy \
  -c "Add :NSSupportsSuddenTermination bool false" \
  -c "Add :NSSupportsAutomaticTermination bool false" \
  "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
codesign --verify --verbose=2 "$APP" || {
  echo "::error::ad-hoc signature failed verification" >&2
  exit 1
}

# Report what the binary links against. If any path here points into .build, the
# app only runs on the machine that built it — package-internal targets are meant
# to be linked statically into the executable, and this is the check that catches
# it if that ever changes.
echo "--- linked libraries ---"
otool -L "$APP/Contents/MacOS/Zenith" | sed 's/^/  /'

if otool -L "$APP/Contents/MacOS/Zenith" | grep -q '\.build'; then
  echo "::error::the app links against libraries inside .build and will not run elsewhere" >&2
  exit 1
fi

echo "--- bundle ---"
find "$APP" -maxdepth 3 | sed 's/^/  /'
