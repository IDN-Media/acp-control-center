#!/bin/zsh
# Package ACP Control Center into a release artifact.
#
# Usage:
#   Scripts/package-release.sh <version> [--sign]
#
# Examples:
#   Scripts/package-release.sh 0.1.0-preview.1                 # unsigned ZIP
#   ACC_SIGNING_IDENTITY="Developer ID Application: IDN Media..." \
#   ACC_NOTARY_PROFILE="ACCNotaryProfile" \
#   Scripts/package-release.sh 0.1.0-preview.1 --sign           # signed + notarized
#
# Outputs (in dist/):
#   ACPControlCenter-<version>-macos.zip
#   ACPControlCenter-<version>-macos.zip.sha256
#
# Signing inputs come from the environment, never from this repository:
#   ACC_SIGNING_IDENTITY  codesign identity, e.g. "Developer ID Application: ..."
#   ACC_NOTARY_PROFILE    keychain profile name created via `xcrun notarytool store-credentials`
#   ACC_TEAM_ID           Apple Developer team ID (passed to xcodebuild as DEVELOPMENT_TEAM)
#
# Without ACC_SIGNING_IDENTITY the script builds an unsigned ZIP (contributor mode).

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version> [--sign]" >&2
  exit 64
fi

VERSION="$1"
SIGN_MODE=0
if [[ "${2:-}" == "--sign" ]]; then
  SIGN_MODE=1
fi

PROJECT="ACPControlCenter.xcodeproj"
SCHEME="ACPControlCenter"
APP_NAME="ACPControlCenter"
BUNDLE_ID="com.idnmedia.acpcontrolcenter"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.derivedDataRelease"
STAGING="$ROOT_DIR/dist/staging"
DIST="$ROOT_DIR/dist"
APP_PATH="$STAGING/$APP_NAME.app"
ZIP_PATH="$DIST/ACPControlCenter-$VERSION-macos.zip"

echo "==> Packaging ACPControlCenter $VERSION"

if [[ ! -d "$ROOT_DIR/$PROJECT" ]]; then
  echo "error: $PROJECT not found (run from the repository root)" >&2
  exit 1
fi

echo "==> Cleaning"
rm -rf "$DERIVED_DATA" "$STAGING" "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$STAGING" "$DIST"

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGNING_ALLOWED=NO
)

if [[ $SIGN_MODE -eq 1 ]]; then
  if [[ -z "${ACC_SIGNING_IDENTITY:-}" ]]; then
    echo "error: ACC_SIGNING_IDENTITY is required for --sign" >&2
    exit 1
  fi
  if [[ -n "${ACC_TEAM_ID:-}" ]]; then
    BUILD_ARGS+=(DEVELOPMENT_TEAM="$ACC_TEAM_ID")
  fi
fi

echo "==> Building Release (xcodebuild)"
xcodebuild "${BUILD_ARGS[@]}" build

echo "==> Staging app bundle"
APP_BUILT="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_BUILT" ]]; then
  echo "error: built app not found at $APP_BUILT" >&2
  exit 1
fi
cp -R "$APP_BUILT" "$APP_PATH"

if [[ $SIGN_MODE -eq 1 ]]; then
  echo "==> Codesigning with: $ACC_SIGNING_IDENTITY"
  codesign --force --options runtime --sign "$ACC_SIGNING_IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  if [[ -n "${ACC_NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$APP_PATH" --keychain-profile "$ACC_NOTARY_PROFILE" --wait

    echo "==> Stapling"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"

    echo "==> Gatekeeper assessment"
    spctl --assess --type execute --verbose=4 "$APP_PATH"
  else
    echo "==> Skipping notarization (ACC_NOTARY_PROFILE not set)"
  fi
else
  echo "==> Unsigned build (no codesign)"
fi

echo "==> Creating ZIP"
(cd "$STAGING" && ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH")

echo "==> Checksum"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo
echo "==> Done"
echo "  ZIP:     $ZIP_PATH"
echo "  SHA256:  $ZIP_PATH.sha256"
echo "  SHA256:  $(awk '{print $1}' "$ZIP_PATH.sha256")"
