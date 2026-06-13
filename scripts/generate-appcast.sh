#!/usr/bin/env bash
#
# Regenerate releases/appcast.xml from whatever zips are sitting in releases/. Useful when
# you want to edit release notes (the <description> CDATA in appcast.xml) without rebuilding
# the app — change appcast.xml, re-run this to refresh signatures + dates.
#
# Reads the same EdDSA private key from the keychain via Sparkle's generate_appcast tool.

set -euo pipefail

cd "$(dirname "$0")/.."

RELEASES_DIR="releases"

if ! command -v generate_appcast >/dev/null 2>&1; then
    echo "ERROR: generate_appcast not found on PATH." >&2
    echo "       See docs/release-setup.md." >&2
    exit 67
fi

if [[ ! -d "${RELEASES_DIR}" ]] || [[ -z "$(ls -A "${RELEASES_DIR}"/*.zip 2>/dev/null)" ]]; then
    echo "ERROR: no zip files in ${RELEASES_DIR}/. Run scripts/release.sh first." >&2
    exit 68
fi

generate_appcast "${RELEASES_DIR}"
echo "==> Regenerated ${RELEASES_DIR}/appcast.xml"
