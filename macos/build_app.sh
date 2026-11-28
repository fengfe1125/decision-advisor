#!/usr/bin/env zsh
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MACOS_DIR"

APP_NAME="成长决策顾问"
EXEC_NAME="DecisionAdvisor"
BUNDLE_ID="com.sakura.decision-advisor"
VERSION="0.16"
# CFBundleVersion 由版本号推导：0.13 -> 13，1.00 -> 100（保证单调递增）
BUILD_NUM="$(( 10#${VERSION//./} ))"
MIN_MACOS="14.0"
DIST_DIR="$MACOS_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :Version' /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/SDKSettings.plist 2>/dev/null || echo '27.0')"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/CoreServices/SystemVersion.plist 2>/dev/null || true)"

echo "=== 1. Compiling native macOS SwiftUI app (Release, v${VERSION}, SDK ${SDK_VERSION}) ==="
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXEC_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: Compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "=== 2. Assembling ${APP_NAME}.app bundle (pure remote VPS client) ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

# Fix Swift 6.4 swiftbuild LC_BUILD_VERSION bug where `sdk` mirrors `minos` (14.0)
# instead of the linked macOS SDK (e.g. 27.0), enabling native macOS 27 Liquid Glass
# window chrome and Liquid Glass traffic lights.
if command -v vtool >/dev/null 2>&1; then
  echo "=== 2b. Stamping LC_BUILD_VERSION (minos ${MIN_MACOS}, sdk ${SDK_VERSION}) ==="
  vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
    -output "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME" \
    "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
fi

# App icon: prefer the Icon Composer source (Assets/AppIcon.icon, full-bleed artwork) compiled by
# actool into Assets.car + AppIcon.icns. macOS 26+ then masks it to the system squircle so it fills
# the Dock/Finder slot instead of being shrunk inside a grey "legacy icon" plate.
# Falls back to the old pre-masked PNG -> iconutil path when Xcode's actool is unavailable.
ICON_COMPOSER_SRC="$MACOS_DIR/Assets/AppIcon.icon"
ICON_SRC="$MACOS_DIR/Assets/AppIcon.png"
EMBLEM_SRC="$MACOS_DIR/Assets/AppIconEmblem.png"
ICONSET_DIR="$MACOS_DIR/.build/AppIcon.iconset"
ICON_NAME_PLIST=""

if [[ -d "$ICON_COMPOSER_SRC" ]] && xcrun --find actool >/dev/null 2>&1; then
  echo "=== 2c. Compiling Assets/AppIcon.icon with actool (full-bleed, system-masked) ==="
  xcrun actool "$ICON_COMPOSER_SRC" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" \
    --app-icon AppIcon \
    --include-all-app-icons \
    --output-partial-info-plist "$MACOS_DIR/.build/AppIcon-partial.plist" \
    --output-format human-readable-text >/dev/null
  ICON_NAME_PLIST=$'  <key>CFBundleIconName</key>\n  <string>AppIcon</string>'
else
  if [[ ! -f "$ICON_SRC" ]]; then
    echo "ERROR: Master icon not found at $ICON_SRC" >&2
    exit 1
  fi

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  echo "=== 2c. Building AppIcon.icns from Assets/AppIcon.png (actool unavailable) ==="
  typeset -a ICON_SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
  )

  for entry in "${ICON_SIZES[@]}"; do
    px="${entry%%:*}"
    fname="${entry##*:}"
    if [[ "$px" == "1024" ]]; then
      cp "$ICON_SRC" "$ICONSET_DIR/$fname"
    else
      sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET_DIR/$fname" >/dev/null
    fi
  done

  iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

if [[ -f "$EMBLEM_SRC" ]]; then
  cp "$EMBLEM_SRC" "$APP_BUNDLE/Contents/Resources/AppIconEmblem.png"
fi

cat >"$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXEC_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
${ICON_NAME_PLIST}
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUM}</string>
  <key>DTPlatformName</key>
  <string>macosx</string>
  <key>DTPlatformVersion</key>
  <string>${SDK_VERSION}</string>
  <key>DTSDKName</key>
  <string>macosx${SDK_VERSION}</string>
  <key>DTSDKBuild</key>
  <string>${SDK_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

DO_INSTALL=false
DO_PACKAGE=false
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=true ;;
    --package) DO_PACKAGE=true ;;
  esac
done
if [[ "$DO_INSTALL" == true || ( "$DO_PACKAGE" == false && -w "/Applications" ) ]]; then
  echo "=== 3. Installing / overwriting /Applications/${APP_NAME}.app ==="
  rm -rf "/Applications/${APP_NAME}.app"
  ditto "$APP_BUNDLE" "/Applications/${APP_NAME}.app"
  touch "/Applications/${APP_NAME}.app"
fi

# Release asset consumed by the in-app updater (UpdateChecker.swift looks for
# "DecisionAdvisor-v<ver>-macOS.zip" on the public mirror's GitHub Release).
if [[ "$DO_PACKAGE" == true ]]; then
  ZIP_PATH="$DIST_DIR/DecisionAdvisor-v${VERSION}-macOS.zip"
  echo "=== 4. Packaging release asset ${ZIP_PATH:t} ==="
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  shasum -a 256 "$ZIP_PATH"
fi

echo "=== BUILD COMPLETE ==="
echo "App Bundle: $APP_BUNDLE"
echo "Version:    ${VERSION} (${BUILD_NUM})"
echo "SDK Target: macOS ${SDK_VERSION} (minOS ${MIN_MACOS})"
if command -v vtool >/dev/null 2>&1; then
  vtool -show-build "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME" | grep -E "minos|sdk" || true
fi
ls -lh "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
