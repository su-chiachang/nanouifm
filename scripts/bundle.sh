#!/usr/bin/env bash
# Builds a Release nanofm and wraps it as build/nanofm.app, then writes build/release/nanofm-<version>-macos.zip.
#
# Signing (environment variables):
#   SIGN_IDENTITY   Code signing identity. Default "-" (ad-hoc). For distribution use
#                   "Developer ID Application: <Name> (<TEAMID>)"; this also enables the hardened
#                   runtime and a secure timestamp.
#   NOTARY_PROFILE  notarytool keychain profile (created with `xcrun notarytool store-credentials`).
#                   When set, the app is notarized, the ticket is stapled, and Gatekeeper is checked.
#                   Requires a Developer ID SIGN_IDENTITY.
#   OPTIMIZE        Zig optimize mode. Default ReleaseSafe (ReleaseSmall and ReleaseFast also work).
#   VERSION         Marketing version. Default: .version in build.zig.zon.
#
# Nothing here opens a window: the bundle is built and inspected, never launched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
BUNDLE_ID="dev.local.nanofm"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "error: NOTARY_PROFILE needs SIGN_IDENTITY set to a \"Developer ID Application: …\" identity" >&2
    exit 1
fi

VERSION="${VERSION:-$(sed -n 's/.*\.version *= *"\([^"]*\)".*/\1/p' build.zig.zon | head -1)}"
VERSION="${VERSION:-0.0.1}"

# Prefer rtk when present (machine convention).
if command -v rtk >/dev/null 2>&1; then RUN=(rtk); else RUN=(); fi

"${RUN[@]}" zig build -Doptimize="$OPTIMIZE" --prefix build/zig-out

BIN="$ROOT/build/zig-out/bin/nanofm"
[[ -x "$BIN" ]] || { echo "error: $BIN was not built" >&2; exit 1; }

APP="$ROOT/build/nanofm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/nanofm"

# App icon: Resources/AppIcon.iconset -> AppIcon.icns.
if [[ -d Resources/AppIcon.iconset ]]; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>nanofm</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>nanofm</string>
    <key>CFBundleDisplayName</key><string>nanofm</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>nanofm</string>
    <key>NSDesktopFolderUsageDescription</key><string>nanofm browses and indexes your Desktop folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>nanofm browses and indexes your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>nanofm browses and indexes your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>nanofm browses removable volumes.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>nanofm browses network volumes.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

OUT="$ROOT/build/release"
ZIP="$OUT/nanofm-$VERSION-macos.zip"
rm -rf "$OUT"
mkdir -p "$OUT"

if [[ -n "$NOTARY_PROFILE" ]]; then
    UPLOAD="$OUT/notarize-upload.zip"
    ditto -c -k --keepParent "$APP" "$UPLOAD"
    echo "Submitting to Apple notary service (profile: $NOTARY_PROFILE)…"
    RESULT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
    echo "$RESULT"
    rm -f "$UPLOAD"
    if ! grep -q "status: Accepted" <<<"$RESULT"; then
        ID="$(sed -n 's/^ *id: //p' <<<"$RESULT" | tail -1)"
        echo "error: notarization was not accepted." >&2
        [[ -n "$ID" ]] && echo "See the log: xcrun notarytool log $ID --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    spctl --assess --type exec --verbose=2 "$APP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP"
echo "Archive $ZIP"
shasum -a 256 "$ZIP"
