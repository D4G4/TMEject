# Testing

TMEject has two test targets:

- **`TMEjectTests`** — pure unit tests over the state machine, ejector, FDA prober, etc.
  Fast; run on every change.
- **`TMEjectSnapshotTests`** — image-diff snapshots of every UI surface. Slower; explicit.

## Unit tests

```
xcodebuild -project TMEject.xcodeproj -scheme TMEject test \
    -destination 'platform=macOS'
```

114 tests, ~2s. The default `cmd-U` in Xcode runs them.

## Snapshot tests

Separate target — runs only when you ask:

```
xcodebuild -project TMEject.xcodeproj -scheme TMEject test \
    -destination 'platform=macOS' -only-testing:TMEjectSnapshotTests
```

51 baselines under `TMEjectSnapshotTests/__Snapshots__/`, one per surface × theme ×
(opaque|translucent). Compared with a 0.5% perceptual-pixel tolerance (sub-LSB AA noise
filtered out at a 0.12 per-channel delta threshold — Blink's tuned values).

### After an intentional UI change

```
SNAPSHOT_RECORD=1 xcodebuild ... -only-testing:TMEjectSnapshotTests test
./scripts/promote-snapshots.sh
git diff TMEjectSnapshotTests/__Snapshots__/      # eyeball the changes
git add TMEjectSnapshotTests/__Snapshots__/
```

The record path writes to `~/Library/Application Support/TMEjectSnapshots/` (hardened
runtime can't write to the source tree from inside the test process). The promote script
copies them in. Review the diff before committing.

### When a snapshot fails unexpectedly

The failure message prints two paths under `~/Library/Application
Support/TMEjectSnapshots/__Failures__/`: `<name>_actual.png` and `<name>_reference.png`.
Open them side-by-side. Three outcomes:

1. **Real regression** — fix the code, re-run. Snapshot passes.
2. **Intentional UI change** — re-record per above.
3. **Flake** — re-run the test. If it still fails, the rendering is non-deterministic;
   open an issue.

### Coverage

| Surface | States × themes × surface modes | Count |
|---|---|---|
| `MenuBarIconView` | 5 states × 2 themes (template — no surface mode) | 10 |
| `MenuBarPopoverView` | 5 states × 2 themes × 2 modes (idle only for translucent) | 11 |
| Ritual confirm overlay | 3 progresses × 2 themes (always opaque) | 6 |
| `LaunchHUDView` | 2 themes × 2 surface modes | 4 |
| `OnboardingView` (modal) | 2 themes × 2 surface modes | 4 |
| `SettingsView` | 2 variants (default, fda_pill) × 2 themes × 2 surface modes (default only) | 6 |
| `ToastView` | 4 kinds × 2 themes (opaque) + 1 translucent representative | 9 |

Skipped: dynamic-Type variants (locked to `.large` in the test environment), additional
Settings variants (Troubleshooting expanded, auto-eject off) — current 51 cover the
visually-distinct cases; expand later if a regression slips through.

### Determinism rules baked into `SnapshotTestCase`

- Locale forced to `en_US`.
- `sizeCategory` forced to `.large`.
- `colorScheme` forced per call site.
- Surfaces rendered at 2× via `ImageRenderer` (or via `NSHostingView` for ScrollView-based
  surfaces).
- Translucency preference set in `UserDefaults.standard` for the duration of the render,
  then restored.

Time-based strings (e.g. "backed up 2:14 PM") are NOT yet stable — current popover
snapshot uses the idle state where no time is shown. If we later add time-dependent
surfaces, inject a fake clock there.
