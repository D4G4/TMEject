# DNC notification discovery procedure

This document is the runbook for discovering the distributed-notification names
`backupd` actually posts. The names are undocumented; Apple has changed them
across macOS versions. Re-run this procedure after every major OS update before
relying on the wake-optimization layer in Step 13.

## Why this exists

TMEject's correctness rests on polling (see `architecture.md`). DNC and FSEvents
layer on top to reduce wake latency — the moment `backupd` flips state, we want
to know *now*, not 30 seconds later when our next poll fires.

To wire DNC we need the actual notification name strings `backupd` is posting.
Those aren't in any public header. The discovery procedure below captures them
from a running system.

## Two buses

Swift's `DistributedNotificationCenter.default` wraps the **per-user bus** only.
`backupd` runs as root and posts on the **system bus**. Listening only via
Swift's wrapper will silently capture nothing.

To capture from BOTH buses you need to use Core Foundation's
`CFNotificationCenterGetDistributedCenter` directly — that one resolves to the
*system* notification center when the caller is privileged enough to observe
it, and to the user one otherwise. We add observers via the Swift wrapper for
the per-user case AND via the CF API for the system case; whichever bus the
notification actually came from will hit the matching observer.

## Discovery procedure

### 1. Add the wildcard observer

In `TMEjectApp.init` (or behind a debug flag — see step 5), install a
`forName: nil` observer that logs every notification it sees:

```swift
NotificationCenter.default.addObserver(
    forName: nil, object: nil, queue: .main
) { note in
    TMEjectLog.observer.info("DNC: \(note.name.rawValue) object=\(note.object ?? "nil") userInfo=\(note.userInfo ?? [:])")
}

DistributedNotificationCenter.default().addObserver(
    forName: nil, object: nil, queue: .main
) { note in
    TMEjectLog.observer.info("DNC user-bus: \(note.name.rawValue) object=\(note.object ?? "nil") userInfo=\(note.userInfo ?? [:])")
}
```

For the system bus, drop into Core Foundation:

```swift
let center = CFNotificationCenterGetDistributedCenter()
CFNotificationCenterAddObserver(
    center,
    Unmanaged.passUnretained(<some Sendable token>).toOpaque(),
    { _, _, name, object, userInfo in
        let nameStr = name?.rawValue as String? ?? "<nil>"
        let log = "DNC system-bus: \(nameStr)"
        // can't call TMEjectLog from a C callback without bouncing — write to os_log directly
        os_log("%{public}@", log)
    },
    nil,            // catch every name
    nil,            // catch every object
    .deliverImmediately
)
```

`object: nil` and `name: nil` together capture every notification on each bus,
which is what we want during discovery.

### 2. Kick off a real backup

Make sure your Time Machine destination is reachable, then start a backup. You
need to capture the actual ENTERING-BACKINGUP and LEAVING-CONFIRMING moments —
not just the in-flight progress.

```
tmutil startbackup --block
```

The `--block` flag holds the shell until the backup completes, which is useful
for stamping the start/end times. Let it run to completion.

### 3. Grep the captured names

The log lines from step 1 land in TMEject's session log at
`~/Library/Application Support/TMEject/Logs/<YYYY-MM-DD>/session-<H-MM-SS>-<AM/PM>.log`.

Filter for the relevant entries:

```
LOG=~/Library/Application\ Support/TMEject/Logs/$(date +%Y-%m-%d)/session-*.log
ls -t $LOG | head -1 | xargs grep -E "DNC( user-bus| system-bus)?:" | sort -u
```

You're looking for names containing `backupd`, `TimeMachine`, `MobileBackups`,
`backup`. Discard system-wide noise (display sleep, screen wake, accessibility
events). The names worth recording are the ones that fire at distinct points
in the backup lifecycle:
- before `Running=1` shows up in `tmutil status -X` (start signal)
- around the phase transition into Finishing/ThinningPostBackup
- after `Running=0` returns to `tmutil status -X` (end signal)

### 4. Confirmed names on macOS 26.3.1 (Tahoe)

> **TBD — populate during Step 13 live discovery.** This section will list the
> notification names captured above, paired with the moment each fires
> relative to `tmutil status -X` so the wake-optimization observer can map
> them to the right state-machine event.

The names should land in `Observation/PollingObserver.swift` (or a sibling
`Observation/WakeNotifier.swift`) as constants with a comment block linking
back here.

### 5. Remove the wildcard observer before shipping

The `forName: nil` observer is for discovery ONLY. Leaving it in shipping code
floods our log, adds CPU overhead, and is a privacy concern (every system
notification flowing through the user's Mac would be captured in our log).
Once discovery is complete:

1. Replace the wildcard observers with named observers for the specific names
   from step 4.
2. Confirm the named observers fire in a second `tmutil startbackup --block`
   run.
3. Remove the wildcard code paths and the temporary log lines.

### 6. Re-verification on future macOS releases

When a new major macOS version ships (e.g. 27.0):

1. Re-add the wildcard observers from step 1.
2. Run step 2 (start a real backup).
3. Compare the captured names against the list in section 4 above.
4. Update section 4 with any deltas.
5. Update `Observation/WakeNotifier.swift` to match.
6. Remove the wildcard observers again per step 5.

Park the version + date you ran this in a comment at the top of section 4 so
future-you knows when the last verification happened.

## Why FSEvents matters too

Even with the right DNC names, FSEvents on the Time Machine plist
(`~/Library/Preferences/com.apple.TimeMachine.plist` or its equivalent on the
destination) is a useful redundant signal. If a DNC name shifts mid-OS-release
and we miss it, the plist change is a backup-of-the-backup wake source. Wire
FSEvents at the same time as the named DNC observers and treat them as an OR:
either one fires → poll immediately.
