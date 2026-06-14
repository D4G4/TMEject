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

> **TBD — populate after the first Step 13 discovery backup.** This section will list the
> `eventMessage` strings paired with the backup-lifecycle moment each fires. Codify them
> in `Observation/KnownLogEvents.swift` as substring matchers — those are
> state-machine-agnostic; they only nudge the poller.

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
