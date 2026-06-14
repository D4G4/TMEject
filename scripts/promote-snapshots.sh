#!/usr/bin/env bash
#
# Promote freshly-recorded snapshot PNGs from the container's TMEjectSnapshots/ directory
# into the source-tree TMEjectSnapshotTests/__Snapshots__/ baselines.
#
# The two-step flow:
#   1. SNAPSHOT_RECORD=1 xcodebuild -only-testing:TMEjectSnapshotTests test
#   2. ./scripts/promote-snapshots.sh
#
# Why two steps: the test host process is hardened-runtime-signed and can't write outside
# its container without TCC-prompting the user. Routing through ~/Library/Application
# Support and a deliberate copy is the simpler path.

set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE_DIR="TMEjectSnapshotTests/__Snapshots__"
CONTAINER_DIR="$HOME/Library/Application Support/TMEjectSnapshots"

if [[ ! -d "${CONTAINER_DIR}" ]] || [[ -z "$(ls -A "${CONTAINER_DIR}"/*.png 2>/dev/null)" ]]; then
    echo "No PNGs in ${CONTAINER_DIR}/. Did you run with SNAPSHOT_RECORD=1?" >&2
    exit 1
fi

mkdir -p "${SOURCE_DIR}"
echo "==> Copying $(ls -1 "${CONTAINER_DIR}"/*.png 2>/dev/null | wc -l | tr -d ' ') snapshots to ${SOURCE_DIR}/"
cp "${CONTAINER_DIR}"/*.png "${SOURCE_DIR}/"

# Clean up container so the next record run starts fresh.
rm -f "${CONTAINER_DIR}"/*.png
echo "==> Done. Review with: git status ${SOURCE_DIR}"
