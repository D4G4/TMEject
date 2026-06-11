# TMEject

A macOS menu bar app that auto-ejects your Time Machine drive after each successful backup.

## Status

**Work in progress** — initial implementation.

## Compatibility

Tested on **macOS 26.3.1 (Tahoe)**. The Time Machine observation layer relies on undocumented `backupd` notification names that may change across macOS versions — re-verify the discovery procedure (see `docs/dnc-discovery.md`) on each OS update.

## Architecture (one-line)

Polling `tmutil status -X` is the primary signal. `DistributedNotificationCenter` + FSEvents on the TM plist are wake-optimizations only. Success is detected by the `tmutil latestbackup` snapshot path advancing — not by `BackupPhase`. Ejection uses DiskArbitration's volume-only `DADiskUnmount` (not whole-device eject) with a 7-step retry schedule and `lsof` diagnostic on failure.

## Distribution

Non-sandboxed, Developer ID signed and notarized. Auto-updates via Sparkle 2.x against an appcast hosted on GitHub Pages.

## Build

```
xcodegen generate
open TMEject.xcodeproj
```

Requires Xcode 16+ and Swift 6.

## License

TBD.
