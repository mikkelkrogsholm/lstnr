#!/usr/bin/env bash
#
# build-dmg.sh — build, sign, (optionally) notarize, and package Vara as a
# styled, distributable DMG.
#
# DESIGN GOALS:
#   * Run TODAY on a machine that only has the "Apple Development" cert — it
#     produces a dev-signed, un-notarized DMG and tells you exactly what is
#     missing for a public release. It exits 0 in that case (it is not a
#     failure, just a local build).
#   * When a "Developer ID Application" cert AND a stored notarytool profile
#     exist, it re-signs with the Developer ID identity, notarizes, and staples.
#
# WHY WE BUILD WITH CODE_SIGNING_ALLOWED=NO THEN RE-SIGN BY HAND:
#   Xcode's automatic signing uses the development cert and the wrong
#   entitlements/options for distribution. We let Xcode produce an UNSIGNED
#   .app, then sign inside-out (frameworks first, then the app bundle) with the
#   hardened runtime (--options runtime) and our committed entitlements, which
#   is what notarization requires.
#
# USAGE:
#   bash scripts/build-dmg.sh
#
# To enable notarization, first store credentials once:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#       --apple-id "you@example.com" --team-id 3B7KHK6C9K --password <app-specific-pw>

set -euo pipefail

# ---- Configuration -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/Lstnr.xcodeproj"
SCHEME="Lstnr"
CONFIGURATION="Release"
APP_NAME="Vara"
PRODUCT_NAME="Vara"
BUNDLE_ID="dk.56n.lstnr"
TEAM_ID="3B7KHK6C9K"
ENTITLEMENTS="$REPO_ROOT/App/Lstnr.entitlements"
NOTARY_PROFILE="${LSTNR_NOTARY_PROFILE:-lstnr-notary}"

# Version comes from the Info.plist short version string so the DMG name tracks
# the marketing version without a second source of truth.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/App/Info.plist" 2>/dev/null || echo "0.1.0")"

# All output goes under .build/ (already in .gitignore) so a DMG build never
# leaves untracked clutter in the working tree.
BUILD_DIR="$REPO_ROOT/.build/dmg"
DERIVED_DIR="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_NAME="${PRODUCT_NAME}-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
APP_PATH="$STAGING_DIR/${PRODUCT_NAME}.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$1"; }
err()  { printf '\033[31m  ✗ %s\033[0m\n' "$1" >&2; }

# ---- 0. Make sure the Xcode project is up to date ----------------------------
bold "Vara · DMG build  (version $VERSION)"
echo
if command -v xcodegen >/dev/null 2>&1; then
    info "Regenerating Xcode project with XcodeGen..."
    ( cd "$REPO_ROOT" && xcodegen generate >/dev/null )
    ok "Project generated."
else
    warn "xcodegen not found — using the existing $PROJECT as-is."
fi
echo

# ---- 1. Pick a signing identity ----------------------------------------------
# Priority: Developer ID Application (release) > Apple Development (local) > ad-hoc.
SIGN_IDENTITY=""
SIGN_KIND=""
DEVID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$DEVID_IDENTITY" ]; then
    SIGN_IDENTITY="$DEVID_IDENTITY"
    SIGN_KIND="developer-id"
    ok "Signing identity: $SIGN_IDENTITY (Developer ID — release-ready)"
elif [ -n "$DEV_IDENTITY" ]; then
    SIGN_IDENTITY="$DEV_IDENTITY"
    SIGN_KIND="apple-development"
    warn "Signing identity: $DEV_IDENTITY (Apple Development — local build, NOT notarizable)"
else
    SIGN_IDENTITY="-"
    SIGN_KIND="ad-hoc"
    warn "No Developer ID or Apple Development cert found — falling back to ad-hoc signing."
fi
echo

# ---- 2. Build an UNSIGNED Release .app ---------------------------------------
bold "Building $SCHEME ($CONFIGURATION)..."
rm -rf "$DERIVED_DIR" "$EXPORT_DIR" "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$EXPORT_DIR" "$STAGING_DIR"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

BUILT_APP="$DERIVED_DIR/Build/Products/$CONFIGURATION/${PRODUCT_NAME}.app"
if [ ! -d "$BUILT_APP" ]; then
    err "Build did not produce $BUILT_APP"
    exit 1
fi
ok "Built $BUILT_APP"
cp -R "$BUILT_APP" "$APP_PATH"
echo

# ---- 3. Re-sign inside-out with hardened runtime + entitlements --------------
bold "Signing $APP_NAME..."
CODESIGN_OPTS=(--force --timestamp --options runtime)
if [ "$SIGN_KIND" = "ad-hoc" ]; then
    # Ad-hoc cannot use a secure timestamp; drop it so codesign succeeds offline.
    CODESIGN_OPTS=(--force --options runtime)
fi

# Sign nested code (frameworks, dylibs, bundles, helper executables) first.
while IFS= read -r -d '' nested; do
    codesign "${CODESIGN_OPTS[@]}" --sign "$SIGN_IDENTITY" "$nested"
done < <(find "$APP_PATH/Contents" \
    \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -print0 2>/dev/null || true)

# Sign the main bundle last, WITH entitlements (codesign drops them otherwise).
codesign "${CODESIGN_OPTS[@]}" \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

if codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | grep -qi "satisfies its Designated Requirement\|valid on disk"; then
    ok "Signature verifies."
else
    # --verify prints to stderr; re-run for the user to see, but don't abort on
    # ad-hoc where the DR check is weaker.
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" || warn "codesign --verify reported issues (expected for ad-hoc)."
fi
echo

# ---- 4. Stage the DMG layout (.app + /Applications symlink) ------------------
bold "Staging DMG contents..."
ln -sf /Applications "$STAGING_DIR/Applications"
ok "Added /Applications symlink."
echo

# ---- 5. Build a read/write DMG, style it, then compress to read-only ---------
bold "Creating DMG..."
RW_DMG="$BUILD_DIR/${PRODUCT_NAME}-rw.dmg"
VOL_NAME="$PRODUCT_NAME"
rm -f "$RW_DMG"

hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$RW_DMG" >/dev/null
ok "Read/write image created."

# Best-effort Finder window styling (icon positions, no toolbar). This is
# cosmetic; failures (e.g. headless CI, automation not permitted) are non-fatal.
MOUNT_DIR="$(mktemp -d)"
if hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen >/dev/null 2>&1; then
    if osascript >/dev/null 2>&1 <<OSA
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        try
            set position of item "${PRODUCT_NAME}.app" of container window to {150, 200}
            set position of item "Applications" of container window to {410, 200}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
    then
        ok "Applied Finder window styling."
    else
        warn "Finder styling skipped (automation not permitted or headless) — DMG still valid."
    fi
    sync
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
else
    warn "Could not mount image for styling — DMG still valid, just unstyled."
fi
rmdir "$MOUNT_DIR" 2>/dev/null || true

info "Compressing to read-only DMG..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"
ok "DMG created: $DMG_PATH"

# Sign the DMG itself when we have a real identity (not ad-hoc).
if [ "$SIGN_KIND" != "ad-hoc" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH" || warn "Could not sign the DMG (continuing)."
fi
echo

# ---- 6. Notarize + staple, OR explain why it was skipped ---------------------
have_notary_profile() {
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1
}

if [ "$SIGN_KIND" = "developer-id" ] && have_notary_profile; then
    bold "Notarizing (profile: $NOTARY_PROFILE)..."
    if xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
        ok "Notarization accepted."
        bold "Stapling ticket..."
        xcrun stapler staple "$DMG_PATH"
        ok "Stapled."
        xcrun stapler validate "$DMG_PATH" && ok "Staple validates."
        echo
        bold "RELEASE BUILD COMPLETE."
        info "Distributable, notarized DMG: $DMG_PATH"
    else
        err "Notarization failed. Inspect the log with:"
        info "  xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
        exit 1
    fi
else
    echo
    bold "================================================================"
    bold " Notarization SKIPPED"
    bold "================================================================"
    if [ "$SIGN_KIND" != "developer-id" ]; then
        warn "Reason: no \"Developer ID Application\" certificate is installed."
        info "  The DMG was signed with: $SIGN_KIND."
        info "  This build runs fine locally but Gatekeeper will warn other users."
        info "  To make a public release, get a Developer ID Application cert from"
        info "  https://developer.apple.com/account (paid Apple Developer Program)."
    fi
    if ! have_notary_profile; then
        warn "Reason: no notarytool keychain profile \"$NOTARY_PROFILE\" was found."
        info "  Store credentials once (Apple ID + app-specific password):"
        info "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        info "        --apple-id \"you@example.com\" --team-id $TEAM_ID --password <app-specific-pw>"
        info "  (Set LSTNR_NOTARY_PROFILE to use a different profile name.)"
    fi
    echo
    info "Un-notarized DMG (fine for local install / testing): $DMG_PATH"
    info "After installing the .app, re-grant TCC permissions for the new copy:"
    info "    tccutil reset Accessibility $BUNDLE_ID"
    info "    tccutil reset Microphone $BUNDLE_ID"
    info "    tccutil reset ListenEvent $BUNDLE_ID"
    echo
    # A local/un-notarized build is a successful run of this script, not an error.
    exit 0
fi
