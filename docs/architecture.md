# TMEject — architecture

Operator-readable overview. Read alongside the code, not in place of it. The "why"
paragraphs explain decisions that the code can't; the code says "how."

## One-line summary

TMEject **polls `tmutil status -X`** to detect Time Machine backup state, decides
**success by comparing the snapshot path from `tmutil latestbackup` across the
confirming-phase entry/exit**, and ejects the destination volume via
DiskArbitration's **volume-only `DADiskUnmount`** with a bounded retry schedule
and an `lsof` diagnostic on each busy.

## Why polling is the primary signal

`backupd` runs as root. When it broadcasts state changes via distributed
notifications, those go on the **system bus**, not the per-user bus. Swift's
`DistributedNotificationCenter` wraps the per-user bus only — anything posted on
the system bus is invisible to it. We could reach the system bus through Core
Foundation (`CFNotificationCenterGetDistributedCenter` + an Objective-C bridge),
but the notification names `backupd` actually uses are undocumented and have
shifted across macOS versions.

`tmutil status -X` is documented, stable, and accurate. The cost is up-to-30s
latency between a real-world event and our observation — fine for our use case
(eject after a backup that takes minutes to hours). The polling cadence flips
between 30s (idle) and 5s (running or in the confirming phase).

DNC + FSEvents (Step 13, blocked on live-backup discovery) layer on top as
**wake-latency optimizations only** — they make us notice sooner. They are NOT
correctness-critical; if they break, polling still completes every transition.
Do not introduce code paths that rely on a notification firing to make forward
progress.

## States

```
            wake / backupBegan
   ┌─────┐ ────────────────────► ┌──────────┐
   │idle │                       │ backingUp│
   └─────┘ ◄──── backupStopped ──└──────────┘
      ▲    ◄──── stallDetected ──────┘
      │
      │ ejectAttemptCompleted(success)             confirmingEntered
      │                                          ┌────────────────►┌──────────┐
      │                                          │                 │confirming│
      │           ┌──────────┐                   │                 └──────────┘
      └─────────── │ejecting │ ◄──── beginEject ─┤                        │
                  └──────────┘                   │                        │
                       │                         │     confirmingExited   │
                       │                         │   (snapshot advanced)  │
                       │ ejectAttemptCompleted(  │            ↓           │
                       │ success: false)         │      .signalBackupCompleted
                       ▼                         │            │           │
                ┌─────────────────┐              │            ▼           │
                │idleEjectFailed  │ ──── ejectRequested (manual retry)    │
                └─────────────────┘                                       │
                       ▲                                                  │
                       └──────────── confirmingTimedOut (4h cap) ─────────┘
```

Edge cases:
- `confirmingExited` with snapshot NOT advanced (same path or both nil) is
  treated as cancellation — back to `idle`, no eject signal.
- `confirmingExited` with either entry-probe or exit-probe failed is treated as
  cancellation — we can't reliably compare, so we refuse to claim success
  (closes the H2 false-success race; see `StateMachine.swift`).
- `stallDetected` fires when `_raw_totalBytes` hasn't changed for 10 minutes in
  `backingUp` — back to `idle` without an eject.
- `confirmingTimedOut` is a 4h hard cap on the confirming phase — back to `idle`.

The state machine is **pure** — `mutating func handle(_ event) -> GuardOutcome`,
no IO, no clocks. The coordinator runs the emitted `AppCommand` list.

## Why success is detected by snapshot-path delta, not BackupPhase

`BackupPhase` looks like the obvious success signal: it transitions through
`Starting → Copying → ThinningPostBackup → Finishing` and then disappears when
the backup ends. But the SAME sequence — and the same disappearance — happens
when the user cancels a backup or when backupd exits a confirming phase due to
an error. There is no `BackupPhase` value (or absence) that uniquely identifies
a successful backup.

`tmutil latestbackup` returns the path of the most recent completed snapshot.
TMEject captures it on `confirmingEntered`, captures it again on
`confirmingExited`, and declares success iff the path advanced. This is the
authoritative signal that a NEW snapshot was actually written. The
`preConfirmLatestBackup` value is persisted to `UserDefaults` so a TMEject
relaunch mid-confirming can still make the comparison.

## Why retries are bounded with a non-busy fast-exit

`mds_stores`, `backupd`, and macOS' indexing daemons routinely hold open files
on a Time Machine volume for tens of seconds to several minutes after a backup
completes. A single immediate eject attempt would almost always return
`kDAReturnBusy`. So the ejector retries on a back-off schedule:

```
attempt:   1   2    3    4    5     6     7     8
delay:    0s  2s   5s   15s  30s   60s   120s  300s
```

8 attempts total; ~9 minutes of total backoff before giving up. On every busy
return we run `lsof -Fpcn /Volumes/<destination>` and surface the holding
process+pid in the menu bar's "Last error" line + the post-attempt callback so
the user can see WHICH process is keeping the drive open while they wait.

Non-busy DA errors (I/O error, no media, etc.) terminate **immediately** — there
is no point burning the 9-min window on something that won't get better. The
error code from `DADissenterGetStatus` is what makes this distinction possible
(`NSWorkspace.unmountAndEjectDevice` swallows it; `diskutil` doesn't propagate
it cleanly either — both were rejected for this reason).

Volume-only unmount, NOT whole-device eject. A user can plug a Time Machine
volume into a multi-partition SSD without losing access to the other
partitions during the eject.

## Tahoe-specific quirks (macOS 26.x)

Things that work differently on macOS 26 (Tahoe) than the documented contract
or than older macOS releases. Re-verify each of these on the next major OS
update — they're the most likely places to break.

### `tmutil destinationinfo -X` returns `ID`, not `DestinationID`

The legacy plist key was `DestinationID`. On macOS 26.3.1 the key is `ID`. The
parser in `TMUtil/StatusPlist.swift` (`DestinationInfo.parseList`) defensively
accepts both. If a future release flips back to `DestinationID` we already
handle it; if it switches to yet another name, the parser will silently return
zero destinations.

### `NSApp.activate(ignoringOtherApps:)` is unreliable past macOS 14

Sonoma+ routinely ignores the focus-steal request. Launch-time setup windows
(onboarding, settings, launch HUD) use the `NSWindow.surfaceAtLaunch()` helper
— one-shot `.floating` elevation for 600ms to win the launch focus race, then
drop back to `.normal`. Don't permanently float setup windows; that puts them
above legitimate work.

### `User.menu/Contents/Resources/CGSession` is the screen-lock fallback path

Apple's documented screen-lock APIs (`SACLockScreenImmediate` from Security.framework)
have been quietly deprecated; `CGSession -suspend` is what works on 26.x. The
binary path is checked at `Lock/ScreenLocker.swift` init — if it disappears in
a future release, `lockScreen()` returns `.binaryMissing` distinctly so we can
surface "screen lock unavailable on this OS version" rather than silently
failing.

### Apple's Sandbox would block too much; we ship unsandboxed

DiskArbitration `DADiskUnmount` from inside an App Sandbox container requires
the `com.apple.security.device.usb` and `com.apple.security.device.audio-video`
entitlements depending on the device, plus user-driven file access prompts on
each volume path. Running unsandboxed (Developer ID + notarized) is the
documented Apple recommendation for menu-bar utilities that need raw device
access. The cost is mandatory notarization on every release; the benefit is no
prompts on volume paths and full DA semantics.

## Eject-then-lock + cooldown

Auto-eject **defaults OFF** on first run. The user opts in via onboarding or
Settings. Why: hourly Time Machine backups + zero-cooldown auto-eject creates a
trap where the drive ejects, the next hourly backup can't reach it, the user
has to physically reconnect. The 30-minute default cooldown (configurable
0/15/30/60/120 min) gives breathing room.

"Eject & Lock" (default ⌃⌥⌘E) is the "I'm walking away" shortcut. When pressed
during `backingUp` or `confirming`, it prompts via `NSAlert`, then
`tmutil stopbackup`, waits up to 30s for `Running=false` (eagerly drives the
matching shutdown event into the state machine instead of waiting on the next
observer poll), and only then ejects + locks. The same retry schedule and lsof
diagnostic applies to the eject phase.

Lock failure does NOT downgrade the eject to a failure — the eject did succeed.
Lock failure surfaces via the `lastError` line; the user can manually lock from
the menu bar / Control Center.

## Observation: clocks

`MonotonicClock` (`ProcessInfo.systemUptime`) is used for the stall timer and
the confirming hard cap — both of which can run for hours. Wall-clock-based
timers would be vulnerable to NTP corrections during a long backup. The fake
clock in tests drives both timers deterministically.
