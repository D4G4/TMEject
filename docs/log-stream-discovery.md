# Log-stream notification discovery

Procedure for discovering the `backupd` / TimeMachine event messages we want to react to
as wake-latency optimizations. Re-run on each major macOS update.

## Why this exists, and what changed from the original plan

`backupd` runs as root and would post on the system bus, not the per-user bus that
Swift's `DistributedNotificationCenter` wraps. The original Step 13 plan was to install
wildcard observers on both buses and capture names empirically.

That plan is dead. **Since macOS 10.15 (Catalina, Oct 2019),
`addObserver(forName: nil, ...)` on either bus is a privileged operation and silently
fails for non-root processes.** No errors, no events delivered. Confirmed on 26.x. Prior
art (`gettes/TimeMachineMonitor`, `BrianHenryIE/UnmountVolumeAfterTimeMachine`) avoids
DNC entirely.

TMEject pivots to `log stream`. `tmutil status -X` polling remains primary per
Architecture Decision #1.

## How `log stream` works

The `/usr/bin/log` tool subscribes to the unified logging system and emits matching
events as ndjson (one JSON object per line) when `--style=ndjson` is set. Our predicate:

```
(processImagePath CONTAINS "backupd") OR (subsystem == "com.apple.TimeMachine")
```

backupd's own log messages PLUS anything tagged with the TimeMachine subsystem.

`LogStreamObserver` runs `log stream` as a child `Process`, parses each ndjson line, and
fires `onWake()` debounced to 1s. The polling observer is the wake target.

## Discovery procedure

### 1. Launch with the discovery env var

```
TMEJECT_LOG_DISCOVERY=1 open -W -a /path/to/TMEject.app
```

(Or set the env var in the Xcode scheme.) When set, every parsed event lands in the
session log at INFO level as
`log-event ts=... subsystem=... category=... process=... msg=...`.

The flag is off by default — logging every backupd event in shipping builds floods the
session log for no user value.

### 2. Trigger a backup

```
tmutil startbackup --block
```

`--block` holds the shell until the backup completes — useful for stamping start/end
times.

### 3. Grep the session log

```
LOG=~/Library/Application\ Support/TMEject/Logs/$(date +%Y-%m-%d)
ls -t "$LOG"/session-*.log | head -1 | xargs grep "log-event "
```

Look for distinct `eventMessage` strings that mark:
- backupd activity start (before `tmutil status` reports `Running=1`).
- Progress / phase transitions.
- Backup completion — success vs cancellation strings differ.

Discard noise (sandbox logs, dlopen tracing, etc.).

### 4. Confirmed events on macOS 26.3.1 (Tahoe)

Captured 2026-06-14 via `tmutil startbackup --block` with `TMEJECT_LOG_DISCOVERY=1`. The
backup produced 18 464 ndjson events in 87 seconds; 99 % were XPC connection-setup noise
(`com.apple.xpc` subsystem). Only **424 events** landed under
`subsystem == "com.apple.TimeMachine"`, and only a handful of those are state-defining.

The substring matchers below are what `Observation/KnownLogEvents.swift` ships. Each was
verified to fire at a distinct backup-lifecycle moment:

| Matcher | Category | When it fires | Notes |
|---|---|---|---|
| `"Backup requested to last destination"` | `BackupDispatching` | Backup invocation (manual or scheduled) | Earliest signal — fires before backupd opens any XPC session |
| `"Attempting backup with mode"` | `BackupJob` | Immediately after dispatch | Includes trigger mode (`"manual backup"`, etc.) in the message body |
| `"Mounting destination"` | `MountedDestinationManager` | Destination mount for backup session | Includes the destination UUID |
| `"Found a destination disk mounted at"` | `BackupDestination` | Setup phase, once per backup | Includes the volume UUID + mount path |
| `"Completing backup"` | `BackupEngine` | Copy phase finished, finalization begins | Fires ~0.5s before "Successfully completed" |
| `"Successfully completed backing up"` | `BackupEngine` | New snapshot URL committed | **Body includes the new snapshot URL** — would be a clean state-detection source if Decision #1 weren't pinning us to polling |

Explicitly NOT wake-worthy (drowned out by these strings if we left them in):
- `"connection invalid"` — XPC tear-down, fires constantly throughout the session
- `"TRY_ERROR_BLOCK"` — internal error-coercion noise from `DO_OR_BAIL` category
- `"Limiting logging for limit"` — Apple's own log-flood protection

Predicate stays `(processImagePath CONTAINS "backupd") OR (subsystem == "com.apple.TimeMachine")` —
both clauses are useful. The first catches backupd-helper events even if Apple ever drops
the subsystem tag. Filtering on the matcher list happens in
`KnownLogEvents.isWakeWorthy(_:)` after the `log stream` predicate, not in the predicate
itself (Apple's predicate syntax is finicky and can't do substring matching on
`eventMessage`).

### 4.1 Same-window finding — success-detection bug on Tahoe

The discovery backup ALSO surfaced a real bug, **not yet fixed**: snapshot-path delta
detection fails on macOS 26.3.1 because the snapshot URL is committed BEFORE TMEject's
first confirming-phase poll. See `docs/architecture.md` under Tahoe quirks for the trace
and the planned fix.

### 5. Re-verification on future macOS releases

When a new major macOS version ships:

1. Re-launch with `TMEJECT_LOG_DISCOVERY=1`.
2. Run step 2.
3. Compare captured `eventMessage` strings against `KnownLogEvents.swift`.
4. Update; mark removed/renamed strings with a comment.
5. Stamp the date + macOS version of the verification.

Park the version + date you ran this in a comment at the top of `KnownLogEvents.swift`
so future-you knows when the last verification happened.

## Why FSEvents stays planned as a second wake source

Even with the right `log stream` predicates, FSEvents on
`/Library/Preferences/com.apple.TimeMachine.plist` is a useful redundant signal. If a
`log stream` event message shifts mid-OS-release and we miss it, the plist change is a
backup-of-the-backup wake source. To wire: instantiate an FSEventStream watching the
TimeMachine plist file; on event, nudge the poller (same debounce). Either source
firing nudges; whichever fires first wins.

Land FSEvents in a follow-up commit once `KnownLogEvents` is captured.
