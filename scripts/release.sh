#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Parse args.
# --channel <name>: emit <sparkle:channel>name</sparkle:channel> in the
#   printed <item> block so the appcast routes this release only to users
#   who opted into that channel. Omitted = stable (no channel tag, visible
#   to everyone).
CHANNEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--channel <name>]"
            exit 1
            ;;
    esac
done

# Read version from project.yml — match the assignment line specifically
# ("MARKETING_VERSION:" with a colon) so we don't also catch the
# CFBundleShortVersionString: $(MARKETING_VERSION) substitution line.
VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$VERSION" ]; then
    echo "Error: could not read version from project.yml"
    exit 1
fi

# Auto-derive CFBundleVersion. Sparkle uses sparkle:version (=
# CFBundleVersion) as its PRIMARY integer comparator — if two releases
# share the same value, Sparkle answers "up to date" regardless of the
# shortVersionString.
#
# We derive from `git rev-list --count HEAD`, which is monotonic per
# merged commit and reproducible from any clone. Floor at (max published
# sparkle:version in the live appcast) + 1 — the appcast is the
# authoritative record of what's already out there; we refuse to ever
# publish a value that isn't strictly greater. If the network fetch
# fails the floor silently degrades to 0 (back to plain rev-list count).
RAW_BUILD_NUMBER=$(git rev-list --count HEAD)
if [ -z "$RAW_BUILD_NUMBER" ]; then
    echo "Error: could not compute build number from git"
    exit 1
fi

APPCAST_URL="${APPCAST_URL:-https://d4g4.github.io/TMEject/appcast.xml}"
# `|| true` so the bootstrap case (first release ever — no items in the
# appcast yet) doesn't trip pipefail. grep returns 1 on no-match and that
# cascades through with set -e otherwise.
APPCAST_MAX=$(curl -fsSL --max-time 10 "$APPCAST_URL" 2>/dev/null \
    | grep -oE '<sparkle:version>[0-9]+</sparkle:version>' \
    | grep -oE '[0-9]+' \
    | sort -n | tail -1 || true)

if [ -n "$APPCAST_MAX" ] && [ "$APPCAST_MAX" -ge "$RAW_BUILD_NUMBER" ]; then
    BUILD_NUMBER=$((APPCAST_MAX + 1))
    echo "→ floored build number: rev-list=$RAW_BUILD_NUMBER, appcast max=$APPCAST_MAX, using $BUILD_NUMBER"
else
    BUILD_NUMBER=$RAW_BUILD_NUMBER
    echo "→ build number: rev-list=$BUILD_NUMBER (appcast max=${APPCAST_MAX:-unreachable})"
fi

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/TMEject.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/TMEject.dmg"
# Keychain profile holding App Store Connect API key for notarytool.
# Reuses the developer's existing Blink profile — same Apple ID.
NOTARY_PROFILE="${TMEJECT_NOTARY_PROFILE:-AC_NOTARY}"
TEAM_ID="${TMEJECT_TEAM_ID:-6V6FZW3FFN}"

echo "=== Building TMEject v$VERSION ==="

# Clean previous build
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

# Regenerate xcodeproj
echo "→ Generating project..."
xcodegen generate

# Archive.
# Sign the archive directly with the Developer ID Application cert rather
# than the project's default Automatic style. Automatic signing resolves a
# *development* identity for the build phase, which a local Xcode mints on
# demand via the signed-in Apple ID — but CI has no Apple ID session and
# only the Developer ID cert in its keychain, so Automatic fails there with
# "No Mac Development signing certificate". Manual Developer ID needs no
# provisioning profile for this app's entitlements (none beyond hardened
# runtime), so this is deterministic and Apple-ID-independent in both CI
# and local runs.
echo "→ Archiving..."
xcodebuild archive \
    -project TMEject.xcodeproj \
    -scheme TMEject \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# Export with Developer ID Application signing.
echo "→ Exporting (Developer ID)..."
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -quiet

# Verify signed .app + version
echo "→ Verifying signed .app..."
codesign --verify --deep --strict --verbose=2 "$EXPORT_DIR/TMEject.app" 2>&1 | tail -5
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$EXPORT_DIR/TMEject.app/Contents/Info.plist")
echo "  Bundle version: $APP_VERSION"

if [ "$APP_VERSION" != "$VERSION" ]; then
    echo "Error: bundle version ($APP_VERSION) doesn't match project.yml ($VERSION)"
    exit 1
fi

# Stage the app in a temp dir so we can add the Applications icon
echo "→ Staging DMG contents..."
STAGE_DIR="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$EXPORT_DIR/TMEject.app" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Apply system Applications folder icon to the symlink
APP_FOLDER_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
if [ -f "$APP_FOLDER_ICON" ]; then
    cp "$APP_FOLDER_ICON" "$STAGE_DIR/Applications/.VolumeIcon.icns" 2>/dev/null || true
fi

echo "→ Creating DMG..."
create-dmg \
    --volname "TMEject" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "TMEject.app" 160 170 \
    --icon "Applications" 380 170 \
    --hide-extension "TMEject.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGE_DIR/" \
    || true  # create-dmg exits 2 on "no custom icon" warning, which is fine

rm -rf "$STAGE_DIR"

# Sign the DMG itself so Gatekeeper trusts the container, not just the
# .app inside. Required for clean install with no quarantine warnings.
echo "→ Signing DMG..."
codesign --sign "Developer ID Application: DAKSH DAVINDER KUMAR GARGAS ($TEAM_ID)" \
    --timestamp \
    "$DMG_PATH"

# Submit DMG to Apple's notary service. --wait blocks until the result
# comes back (typically 1–5 min).
echo "→ Submitting DMG to notary (this can take several minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# Staple the notarization ticket onto the DMG. After this, Gatekeeper
# trusts the DMG offline — no internet round-trip on the user's Mac.
echo "→ Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

# Final spot-check: spctl should report "accepted" + "source=Notarized
# Developer ID" for the DMG.
echo "→ Gatekeeper assessment..."
spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH" 2>&1 | tail -3

# Sign the DMG with the EdDSA key for Sparkle.
#
# Key source — two paths:
#   1. Local Mac: sign_update reads the private key from the developer's
#      login Keychain (item "https://sparkle-project.org").
#   2. CI: SPARKLE_PRIVATE_KEY_FILE env var points at a file containing
#      the base64-decoded EdDSA private key. sign_update's --ed-key-file
#      reads it directly — no keychain access, no ACL prompts. Mandatory
#      on headless CI.
#
# sign_update lives inside the Sparkle SPM checkout once resolved.
echo "→ EdDSA-signing DMG for Sparkle..."
SPARKLE_BIN=""
SPM_CACHES=(
    "$HOME/Library/Developer/Xcode/DerivedData"
    "$HOME/Library/Caches/org.swift.swiftpm"
)
for cache in "${SPM_CACHES[@]}"; do
    if [ -z "$SPARKLE_BIN" ]; then
        FOUND=$(find "$cache" -type f -name sign_update -path "*Sparkle*/bin/sign_update" 2>/dev/null | head -1)
        [ -n "$FOUND" ] && SPARKLE_BIN="$FOUND"
    fi
done
[ -z "$SPARKLE_BIN" ] && SPARKLE_BIN="$HOME/.local/sparkle-2.9.2/bin/sign_update"

if [ ! -x "$SPARKLE_BIN" ]; then
    echo "Error: sign_update not found. Build the app once so Xcode resolves the Sparkle SPM package, or extract Sparkle to ~/.local/sparkle-2.9.2/."
    exit 1
fi
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    SPARKLE_SIG_LINE=$("$SPARKLE_BIN" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$DMG_PATH")
else
    SPARKLE_SIG_LINE=$("$SPARKLE_BIN" "$DMG_PATH")
fi
echo "  $SPARKLE_SIG_LINE"

# Summary
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
DMG_BYTES=$(stat -f %z "$DMG_PATH")
PUBDATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/D4G4/TMEject/releases/download/v${VERSION}/TMEject.dmg"
RELEASE_NOTES_URL="https://github.com/D4G4/TMEject/releases/tag/v${VERSION}"

# Channel routing: when --channel was passed, inject a <sparkle:channel>
# element so the item only reaches opted-in users.
CHANNEL_LINE=""
if [ -n "$CHANNEL" ]; then
    CHANNEL_LINE="      <sparkle:channel>${CHANNEL}</sparkle:channel>"
fi

# Build the description HTML inline from git log between the previous
# release tag and HEAD. Sparkle renders the CDATA as HTML in a WebView.
PREV_TAG=$(git tag --sort=-v:refname --merged HEAD \
    | grep -v "^v${VERSION}$" \
    | head -1 || true)

CHANGELOG_BLOCK=""
if [ -n "$PREV_TAG" ]; then
    CHANGELOG_LIS=$(git log --no-merges --pretty=format:"%s" "${PREV_TAG}..HEAD" \
        | sed -E '/^(chore|ci|build|docs|test|refactor|style|release)(\([^)]*\))?!?:/d' \
        | sed -E '/^[a-z]+\((release|appcast|deps|ci|build)\)!?:/d' \
        | sed -E 's/^(feat|fix|perf|revert)(\([^)]*\))?!?: ?//' \
        | sed -E 's/ \(#[0-9]+\)$//' \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | awk 'NF { print toupper(substr($0,1,1)) substr($0,2) }' \
        | sed -e 's|^|<li>|' -e 's|$|</li>|' \
        | tr -d '\n')
    if [ -n "$CHANGELOG_LIS" ]; then
        CHANGELOG_BLOCK="<h3 style=\"margin-top:0\">What's new in ${VERSION}</h3><ul>${CHANGELOG_LIS}</ul>"
    fi
fi

DESCRIPTION_HTML="${CHANGELOG_BLOCK}<p style=\"margin-bottom:0\">Full release on <a href=\"${RELEASE_NOTES_URL}\">GitHub</a>.</p>"
APPCAST_ITEM=$(cat <<XML
    <item>
      <title>TMEject v${VERSION}</title>
      <link>${RELEASE_NOTES_URL}</link>${CHANNEL_LINE:+
$CHANNEL_LINE}
      <sparkle:version>$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$EXPORT_DIR/TMEject.app/Contents/Info.plist")</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
      <description><![CDATA[${DESCRIPTION_HTML}]]></description>
      <enclosure url="${DOWNLOAD_URL}"
                 type="application/octet-stream"
                 ${SPARKLE_SIG_LINE} />
    </item>
XML
)

echo ""
echo "=== Done ==="
echo "  DMG: $DMG_PATH ($DMG_SIZE)"
echo "  SHA: $DMG_SHA ($DMG_BYTES bytes)"
echo "  Version: $VERSION (build $BUILD_NUMBER)"
echo ""
echo "=== Appcast item — paste this into site/appcast.xml after <channel> ==="
echo "$APPCAST_ITEM"
# Also write to a file so CI can splice it into site/appcast.xml without
# re-parsing stdout.
echo "$APPCAST_ITEM" > "$BUILD_DIR/appcast-item.xml"
