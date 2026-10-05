#!/bin/zsh
# Builds a distributable, ad-hoc signed Compositor DMG (no Developer ID, no notarization).
#
# Unlike scripts/release.sh this needs no Apple certificates or credentials, so it can
# run on any Mac. The trade-off is that ad-hoc builds are not notarized: on another Mac,
# macOS shows "unidentified developer" the first time it is opened (right-click → Open).
#
# The one non-obvious step below is the `codesign --force --deep --sign -` after the
# build. Xcode signs the Release binary with the hardened runtime, whose library
# validation rejects the embedded Sparkle.framework (also ad-hoc signed) at launch with
# "mapping process and mapped file (non-platform) have different Team IDs". Re-signing
# the whole bundle ad-hoc without the runtime flag makes every embedded binary share the
# same empty Team ID, so dyld can load Sparkle. `ENABLE_HARDENED_RUNTIME=NO` at build
# time does most of the work; the re-sign is the belt-and-braces guarantee.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP=Compositor
WORK="$HOME/Library/Caches/CompositorAdhoc"
DIST="$PROJECT_DIR/dist"

settings=$(xcodebuild -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(print -r -- "$settings" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}')

echo "==> $APP $VERSION"

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"

echo "==> Building Release (ad-hoc, hardened runtime off)"
xcodebuild -project "$PROJECT_DIR/$APP.xcodeproj" -scheme "$APP" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$WORK/DerivedData" build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=NO

APP_PATH="$WORK/DerivedData/Build/Products/Release/$APP.app"

echo "==> Re-signing deep ad-hoc (strip hardened runtime so Sparkle loads)"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "==> Staging + packaging"
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/$APP-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "==> Done: $DMG"
