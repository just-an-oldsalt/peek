#!/usr/bin/env bash
#
# scripts/release.sh — build a signed, notarized Peek release for the
# GitHub Releases channel.
#
# Produces both a .dmg (drag-to-Applications) and a .pkg (Installer.app /
# MDM-friendly) in build/release/artifacts/, plus a SHA-256 sums file and a
# ready-to-paste `gh release create` command at the end.
#
# The Mac App Store build comes from the same sandboxed binary but is
# uploaded via Xcode Organizer (Archive → Distribute → App Store Connect),
# not by this script.
#
# Usage:
#     ./scripts/release.sh VERSION
#
# Example:
#     ./scripts/release.sh 1.0
#
# The VERSION arg must match MARKETING_VERSION in project.pbxproj — bump
# the project version (and commit) first, then run this.
#
# ─── One-time prerequisites ────────────────────────────────────────────
#
# 1. Developer ID Application + Installer certs in your login Keychain:
#        security find-identity -v | grep "Developer ID"
#    Should show both. Add via Xcode → Settings → Accounts → Manage
#    Certificates → +.
#
# 2. notarytool keychain profile saved under the name "peek-notary".
#    Either with an Apple ID + app-specific password (simpler):
#        xcrun notarytool store-credentials peek-notary \
#            --apple-id YOUR_APPLE_ID \
#            --team-id 346JJCHZP7
#    Or with an App Store Connect API key (more portable to CI):
#        xcrun notarytool store-credentials peek-notary \
#            --key /path/to/AuthKey_XXXX.p8 \
#            --key-id XXXXXXXXXX \
#            --issuer YOUR_ISSUER_UUID
#    Override the profile name with PEEK_NOTARY_PROFILE if needed.
#
# 3. Optional: GitHub CLI (`gh`) authenticated, if you want to publish
#    artifacts to a GitHub Release at the end.

set -euo pipefail

# ─── Inputs ────────────────────────────────────────────────────────────

VERSION_ARG="${1:?usage: $0 VERSION (e.g. 1.0) — must match MARKETING_VERSION}"
PROJECT="${PEEK_PROJECT:-peek.xcodeproj}"
SCHEME="${PEEK_SCHEME:-peek}"
TEAM_ID="${PEEK_TEAM_ID:-346JJCHZP7}"
NOTARY_PROFILE="${PEEK_NOTARY_PROFILE:-peek-notary}"
APP_BUNDLE_ID="${PEEK_BUNDLE_ID:-com.oldsalt.peek}"

PROJECT_VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT/project.pbxproj" \
    | sed 's/.*= //;s/;//' | tr -d '[:space:]')

if [ "$VERSION_ARG" != "$PROJECT_VERSION" ]; then
    printf "\033[1;31m✗ Version mismatch: arg=%s, MARKETING_VERSION=%s\033[0m\n" \
        "$VERSION_ARG" "$PROJECT_VERSION" >&2
    printf "  Bump MARKETING_VERSION first, commit, then re-run.\n" >&2
    exit 1
fi
VERSION="$PROJECT_VERSION"

# ─── Layout ────────────────────────────────────────────────────────────

BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/peek.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGE_DIR="$BUILD_DIR/dmg-stage"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

APP="$EXPORT_DIR/peek.app"
DMG="$ARTIFACT_DIR/peek-${VERSION}.dmg"
PKG="$ARTIFACT_DIR/peek-${VERSION}.pkg"

step() { printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }
fail() { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ─── Prereq checks ─────────────────────────────────────────────────────

step "Checking prerequisites"

security find-identity -v | grep -q "Developer ID Application:" \
    || fail "Developer ID Application certificate not in keychain. Add via Xcode → Settings → Accounts → Manage Certificates."

security find-identity -v | grep -q "Developer ID Installer:" \
    || fail "Developer ID Installer certificate not in keychain (needed for .pkg). Add via Xcode → Settings → Accounts → Manage Certificates."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool keychain profile '$NOTARY_PROFILE' not found. See header of this script for setup."

# ─── Clean ─────────────────────────────────────────────────────────────

step "Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$ARTIFACT_DIR" "$STAGE_DIR"

# ─── Archive ───────────────────────────────────────────────────────────

step "Archiving (Release config)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -quiet

# ─── Export with Developer ID signing ──────────────────────────────────

step "Exporting Developer-ID-signed app"
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -quiet

[ -d "$APP" ] || fail "Exported app not found at $APP"

# ─── Verify the .app is signing-clean before notarizing ────────────────

step "Verifying signature & hardened runtime"
codesign --verify --strict --deep "$APP"
codesign_info=$(codesign --display --verbose=4 "$APP" 2>&1)
[[ "$codesign_info" == *"flags=0x"*"(runtime)"* ]] \
    || fail "Hardened Runtime is not enabled on the .app — notarization will reject it. Enable in target → Build Settings → 'Enable Hardened Runtime' = YES."

# ─── Notarize the .app, then staple ────────────────────────────────────

step "Notarizing .app (typically 2–10 min)"
APP_ZIP="$BUILD_DIR/peek-app-for-notary.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

step "Stapling notarization ticket to .app"
xcrun stapler staple "$APP"

# ─── Build, sign, notarize, staple .dmg ────────────────────────────────

step "Building .dmg"
cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create \
    -volname "Peek $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG"

step "Signing .dmg"
codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarizing .dmg"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

step "Stapling .dmg"
xcrun stapler staple "$DMG"

# ─── Build, sign, notarize, staple .pkg ────────────────────────────────

step "Building & signing .pkg"
pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --identifier "${APP_BUNDLE_ID}.installer" \
    --version "$VERSION" \
    --sign "Developer ID Installer" \
    "$PKG"

step "Notarizing .pkg"
xcrun notarytool submit "$PKG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

step "Stapling .pkg"
xcrun stapler staple "$PKG"

# ─── Gatekeeper sanity check ───────────────────────────────────────────

step "Gatekeeper acceptance check"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type install --verbose "$PKG"

# ─── Checksums ─────────────────────────────────────────────────────────

step "Computing SHA-256 sums"
( cd "$ARTIFACT_DIR" && shasum -a 256 *.dmg *.pkg > SHA256SUMS )

# ─── Summary ───────────────────────────────────────────────────────────

cat <<EOF

────────────────────────────────────────────────────────────────────────
✓ Release artifacts ready:
    $DMG
    $PKG
    $ARTIFACT_DIR/SHA256SUMS

To publish to GitHub:

    git tag -a v$VERSION -m "Peek $VERSION"
    git push origin v$VERSION
    gh release create v$VERSION \\
        --title "Peek $VERSION" \\
        --generate-notes \\
        "$DMG" \\
        "$PKG" \\
        "$ARTIFACT_DIR/SHA256SUMS"

(If v$VERSION is already pushed, skip the first two lines.)
────────────────────────────────────────────────────────────────────────
EOF
