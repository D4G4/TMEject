# TMEject

A macOS menu bar app that auto-ejects your local Time Machine drive after each
successful backup, so you can safely unplug a docking station, monitor, or
external SSD without remembering to eject manually.

Non-sandboxed, Developer ID signed and notarized. Auto-updates via Sparkle 2.x.

## What it does

- Watches Time Machine via `tmutil status -X` polling (30s idle / 5s active).
- On a successful backup (detected by `tmutil latestbackup` snapshot path
  advancing — not by `BackupPhase`, which doesn't distinguish success from
  cancellation), runs `DADiskUnmount` on the destination volume.
- Up to 8 retry attempts with a bounded back-off (0, 2, 5, 15, 30, 60, 120,
  300s — ~9 min total) when the volume is busy. On each busy, runs
  `lsof -Fpcn` to surface which process is holding the drive open.
- Non-busy DA errors (I/O, no media) fail fast — no point burning the retry
  window on something that won't get better.
- "Eject & Lock" (default ⌃⌥⌘E) ejects and locks the screen — stops the
  current backup first if one is running.
- Auto-eject defaults **OFF**; user opts in via onboarding or Settings. Hourly
  TM backups + zero-cooldown auto-eject is a trap — the default 30-minute
  cooldown is the recommended balance.

## Compatibility

Tested on **macOS 26.3.1 (Tahoe)** with the bundled Time Machine. Min deployment
target is macOS 14. Re-verify the wake-event discovery procedure on each major
macOS update — see [`docs/log-stream-discovery.md`](docs/log-stream-discovery.md).

## Build

Project file is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
xcodegen generate
xcodebuild -project TMEject.xcodeproj -scheme TMEject build
```

Requires Xcode 16+, Swift 6, XcodeGen 2.x. Swift Package Manager dependencies
(Sparkle 2.x, KeyboardShortcuts 2.x) are resolved by Xcode on first build.

## Test

```
xcodebuild -project TMEject.xcodeproj -scheme TMEject -destination 'platform=macOS' test
```

Tests run headless (no window server needed); the few that exercise UI paths
inject fakes for the screen-lock binary, the confirm dialog, and the toast
presenter.

## Release

Signed/notarized releases use `scripts/release.sh`. One-time setup
(Sparkle EdDSA keys, Developer ID certificate, `notarytool` keychain profile,
GitHub Pages bootstrap) is documented in
[`docs/release-setup.md`](docs/release-setup.md). The release script preflight-
checks all three of those before doing any archive work and refuses to ship
with a `<TODO>` public key in `project.yml`.

## Architecture

See [`docs/architecture.md`](docs/architecture.md) — covers the polling-primary
design and why, the state machine, the snapshot-delta success-detection
rationale, the retry schedule, and the Tahoe-specific quirks worth knowing
about before touching the observation/eject paths.

## Permissions

| Permission | Why TMEject asks |
|---|---|
| Full Disk Access | Required to call `tmutil latestbackup` and to `lsof` the mounted Time Machine volume. Without it, auto-eject can't detect backup completion and the "what's holding the drive" diagnostic returns empty. Required only when **auto-eject** is on; manual eject + Eject & Lock work without it. |
| Notifications | Surfaces backup-complete and eject-failure events. Requested only when you opt in to auto-eject — not at launch. |
| Login Items (SMAppService) | "Launch at login" toggle in Settings. Optional. |

TMEject does **not** request:

- Accessibility — the ⌃⌥⌘E hotkey uses Carbon's `RegisterEventHotKey`, which is
  permission-free.
- Apple Events / Automation — `tmutil stopbackup` runs via `Process`, no AE bridge.
- Removable Volumes (Files & Folders) — Full Disk Access is the umbrella; Apple's
  Removable Volumes pane is a narrower variant we don't need on top.

## Logs

Daily session logs live at:

```
~/Library/Application Support/TMEject/Logs/<YYYY-MM-DD>/session-<H-MM-SS>-<AM/PM>.log
```

Pruned after 7 days. The menu bar's "Reveal logs in Finder" item opens the
current day's directory.

## License

TBD.
