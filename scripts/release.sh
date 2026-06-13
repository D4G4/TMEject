#!/usr/bin/env bash
#
# TMEject release pipeline. Builds a Developer-ID-signed Release archive, notarizes,
# staples, zips, and regenerates the Sparkle appcast.
#
# Prerequisites — see docs/release-setup.md for the one-time setup:
#   1. Sparkle EdDSA keys: `generate_keys` (Sparkle CLI), private in Keychain.
#      Public half pasted into project.yml's INFOPLIST_KEY_SUPublicEDKey field.
#   2. Developer ID Application certificate installed in login keychain.
#   3. `xcrun notarytool store-credentials TMEjectNotary` configured.
#
# Usage:
#   ./scripts/release.sh <version>
#     e.g.  ./scripts/release.sh 0.2.0
#
# Outputs (gitignored):
#   build/TMEject.xcarchive
#   build/export/TMEject.app
#   releases/TMEject-<version>.zip
#   releases/appcast.xml
#
# Does NOT push anything. Final step is a manual git push to gh-pages.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    echo "usage: $0 <version>" >&2
    exit 64
fi

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ---- knobs (override via env) ----
SCHEME="${TMEJECT_SCHEME:-TMEject}"
TEAM_ID="${TMEJECT_TEAM_ID:-}"          # required if not set in Xcode Team
NOTARY_PROFILE="${TMEJECT_NOTARY_PROFILE:-TMEjectNotary}"
ARCHIVE_PATH="build/TMEject.xcarchive"
EXPORT_DIR="build/export"
APP_PATH="${EXPORT_DIR}/TMEject.app"
RELEASES_DIR="releases"
ZIP_PATH="${RELEASES_DIR}/TMEject-${VERSION}.zip"
APPCAST_PATH="${RELEASES_DIR}/appcast.xml"

# ---- preflight ----

# 1. Sparkle public key must be set (placeholder rejected). Sparkle silently lets
#    you ship without it but updates from such a build can't be verified.
if grep -q 'INFOPLIST_KEY_SUPublicEDKey: "<TODO>"' project.yml; then
    echo "ERROR: project.yml still has INFOPLIST_KEY_SUPublicEDKey: \"<TODO>\"." >&2
    echo "       Run \`generate_keys\` (from Sparkle's bin/), keep the private key in" >&2
    echo "       your login keychain, and paste the PUBLIC half into project.yml." >&2
    echo "       See docs/release-setup.md." >&2
    exit 65
fi

# 2. notarytool credentials must be importable. We don't want to discover a
#    missing profile after a 4-min archive + upload.
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "ERROR: notarytool keychain profile \"${NOTARY_PROFILE}\" not found." >&2
    echo "       Run:  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
    echo "                  --apple-id <your@apple.id> --team-id <TEAMID> --password <app-spec-pwd>" >&2
    echo "       See docs/release-setup.md." >&2
    exit 66
fi

# 3. generate_appcast must be available — install from Sparkle's bin/.
if ! command -v generate_appcast >/dev/null 2>&1; then
    echo "ERROR: generate_appcast not found on PATH." >&2
    echo "       Download Sparkle, copy bin/generate_appcast into /usr/local/bin." >&2
    echo "       See docs/release-setup.md." >&2
    exit 67
fi

mkdir -p build "${EXPORT_DIR}" "${RELEASES_DIR}"
rm -rf "${ARCHIVE_PATH}" "${APP_PATH}"

# ---- regenerate project ----
echo "==> xcodegen generate"
xcodegen generate >/dev/null

# ---- archive ----
echo "==> xcodebuild archive  (CFBundleShortVersionString=${VERSION})"
xcodebuild archive \
    -project TMEject.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    | xcbeautify || true

if [[ ! -d "${ARCHIVE_PATH}" ]]; then
    echo "ERROR: archive missing at ${ARCHIVE_PATH}" >&2
    exit 70
fi

# ---- export (Developer ID signed) ----
EXPORT_PLIST="$(mktemp -t TMEjectExportOptions).plist"
cat > "${EXPORT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
$([[ -n "${TEAM_ID}" ]] && printf '    <key>teamID</key><string>%s</string>\n' "${TEAM_ID}")
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF

echo "==> xcodebuild -exportArchive (Developer ID)"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_PLIST}" \
    | xcbeautify || true

if [[ ! -d "${APP_PATH}" ]]; then
    echo "ERROR: exported .app missing at ${APP_PATH}" >&2
    exit 71
fi

# ---- notarize ----
NOTARY_ZIP="build/TMEject-notary.zip"
rm -f "${NOTARY_ZIP}"
ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"

echo "==> notarytool submit (--wait can take 1–10 min)"
xcrun notarytool submit "${NOTARY_ZIP}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# ---- staple ----
echo "==> stapler staple"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

# ---- final user-facing zip ----
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
SHA="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
echo "==> Wrote ${ZIP_PATH}"
echo "    sha256 ${SHA}"

# ---- appcast ----
echo "==> generate_appcast ${RELEASES_DIR}"
generate_appcast "${RELEASES_DIR}"
if [[ ! -f "${APPCAST_PATH}" ]]; then
    echo "ERROR: appcast.xml not written at ${APPCAST_PATH}" >&2
    exit 72
fi

# ---- next steps ----
cat <<EOF

==> Done.

   Release artifact: ${ZIP_PATH}
   Appcast:          ${APPCAST_PATH}

   Next: publish to GitHub Pages so Sparkle's SUFeedURL can reach them.

       git checkout gh-pages
       cp ${RELEASES_DIR}/TMEject-${VERSION}.zip ${RELEASES_DIR}/appcast.xml .
       git add TMEject-${VERSION}.zip appcast.xml
       git commit -m "Release ${VERSION}"
       git push origin gh-pages
       git checkout -

EOF
