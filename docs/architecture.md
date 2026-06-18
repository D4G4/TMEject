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

### `tmutil destinationinfo`'s `ID` is NOT the filesystem volume UUID

Step 4's original brief told the resolver to match `DestinationInfo.id` against
`kDADiskDescriptionVolumeUUIDKey`. End-to-end verification on macOS 26.3.1 showed those
are two orthogonal identifiers:

- `tmutil destinationinfo -X` → `ID = 0852943E-8EC2-4386-8C31-ECE56488E8B4` (TM's
  internal destination-registry UUID)
- `DADiskCopyDescription` on the same mounted volume → `kDADiskDescriptionVolumeUUIDKey
  = 8968B69C-E835-472A-9EA7-F7F6CB22A13C` (the filesystem volume UUID)

Empirical `DADiskCopyDescription` dump exposes zero fields that contain the tmutil ID.
There is no UUID match path through DiskArbitration.

**Fix**: match by tmutil's own `MountPoint` field — `tmutil destinationinfo -X` already
includes the volume's mount path, so the resolver reads it directly from the plist and
asks DA to describe the volume at that path (BSD name + volume name). No matching, no
enumeration. dbdb6cb shipped a name-match fallback as an interim; the MountPoint path
replaced it because tmutil already knows the answer.

If `MountPoint` is absent the resolver returns nil rather than guessing — that means the
destination isn't currently mounted, which is the same outcome as the old code for an
unmounted drive. Test coverage: `DestinationResolverTests` covers MountPoint present
(success), absent (nil), path missing (nil), DA missing description (nil), DA missing
BSD (nil), DA missing volume UUID (still success — UUID isn't required for the unmount
syscall, BSD + path are).

### Snapshot path is written BEFORE TMEject's first confirming-phase poll on macOS 26.3.1

**Fixed in Step 12.7+13 fixup** by moving the baseline capture from `confirmingEntered`
to `backupBegan`. Decision #3 still stands at the policy level — snapshot-path delta IS
the authoritative success signal — but the implementation detail of WHEN to capture the
"before" side of that delta has been corrected for Tahoe's ordering.

Originally locked Decision #3 captured the baseline at `confirmingEntered`. The assumption
was that the new snapshot URL gets committed DURING the confirming phase, so a poll at
confirming-entry returns the PRIOR snapshot URL and a poll at confirming-exit returns the
NEW one.

On macOS 26.3.1 the snapshot is committed BEFORE TMEject's first observation of the
confirming phase. Real trace from the Step 13 discovery backup:

- 14:51:22.246 `[DeferredSizing] Skipping further sizing for finished volume`
- 14:51:22.358 `[BackupEngine] Completing backup`
- 14:51:22.857 `[TMSession] Finishing session for '/Volumes/Daksh's Time Machine'`
- 14:51:22.858 — TMEject sees `BackupPhase != Copying` for the first time → emits
  `confirmingEntered`, captures latestbackup path → `…/2026-06-14-145122.backup`
- 14:51:22.894 `[BackupEngine] Successfully completed backing up 205.7 MB to
  '/Volumes/.timemachine/.../2026-06-14-145122.backup'`
- 14:51:24.667 — TMEject sees `Running=false` → emits `confirmingExited`, captures
  latestbackup path → SAME `…/2026-06-14-145122.backup`
- Old logic: entry == exit → false cancellation → no auto-eject.

**The fix**: `PollingObserver` now captures `tmutil latestbackup` at the moment it emits
`backupBegan` — before backupd has committed the new snapshot — and passes it through as
`baselineLatestBackupPath`. The state machine stores it in `preBackupLatestBackup` (was
`preConfirmLatestBackup`). `confirmingExited` compares `baseline` vs `newPath`. Real
trace with the fix:

- baseline at `backupBegan` ≈ `…/2026-06-13-100000.backup` (yesterday's last backup)
- new at `confirmingExited` = `…/2026-06-14-145122.backup`
- baseline != new → `.signalBackupCompleted` → auto-eject fires

The `entryProbeFailed` channel survives as an OR-accumulator: if FDA grant breaks
mid-backup (entry probe at `confirmingEntered` fails after a successful baseline probe),
the state machine still refuses success. Persisted UserDefaults key renamed
`preConfirmLatestBackupPath` → `preBackupLatestBackupPath`; restoration on relaunch
restores into `.backingUp` OR `.confirming` based on current `tmutil status` phase.

Test coverage: `testTahoeSnapshotRace_SnapshotCommitsBeforeConfirmingEntered_StillCountsAsSuccess`
in `StateMachineTests` simulates the Tahoe ordering and asserts the success path fires.

### `NSDistributedNotificationCenter` wildcard observers are dead since macOS 10.15

Original plan was to subscribe to backupd's distributed notifications via
`NSDistributedNotificationCenter.addObserver(forName: nil, ...)` and discover names
empirically. Since macOS 10.15 (Catalina, Oct 2019) **wildcard observers on
DistributedNotificationCenter — both the per-user bus the Swift wrapper exposes and
the system bus reached via `CFNotificationCenterGetDistributedCenter()` — are a
privileged operation that silently fails for non-root processes**. Tahoe is well past
that cutoff. The code would compile and register without error, then receive nothing.

Wake-latency optimization uses `log stream --predicate '(processImagePath CONTAINS
"backupd") OR (subsystem == "com.apple.TimeMachine")' --info --style=ndjson` instead,
running as a child `Process`. Each backupd/TimeMachine event nudges the polling observer
to run sooner than its scheduled 30s/5s cadence. Polling `tmutil status -X` remains the
PRIMARY observation signal per Decision #1 — log-stream is purely a wake-latency
optimization, never a state driver. Prior art: `gettes/TimeMachineMonitor` and
`BrianHenryIE/UnmountVolumeAfterTimeMachine` both avoid DNC and use the same log-stream
approach.

### `tmutil latestbackup` and `tmutil listbackups` require Full Disk Access

Verified empirically on 26.3.1. The error is distinctive:

```
$ tmutil latestbackup
tmutil: latestbackup requires Full Disk Access privileges.
```

This was NOT documented in older macOS releases. **Critical consequence**: TMEject's
snapshot-path delta success detection (see "Why success is detected by snapshot-path
delta") relies on `tmutil latestbackup`. Without FDA:

- `tmutil status -X` keeps working — we see backups start and end.
- `tmutil destinationinfo -X` keeps working — we can resolve the destination.
- `tmutil latestbackup` refuses → observer marks `entryProbeFailed=true` (and same on
  exit) → state machine safely refuses to claim success → auto-eject **never fires**.
- `lsof` against the mounted TM volume returns an empty holder list — `ls
  /Volumes/<TM-drive>/` itself returns "Operation not permitted" without FDA, so lsof
  sees no files at all there. The "Last error" diagnostic surface in the menu bar then
  reports "no holders found" instead of the real culprit.

In short: without FDA, the post-Copying half of the app is non-functional. The state
machine doesn't malfunction (it correctly refuses to claim success), but the user
experience is "auto-eject doesn't seem to work."

TMEject probes FDA at launch, when Settings opens, when the user toggles auto-eject ON,
and on `NSApplication.didBecomeActiveNotification` (debounced 5s). The
`FullDiskAccessProbing` protocol classifies the result by inspecting `latestbackup`
stderr for the "Full Disk Access" substring — `.granted` / `.denied` / `.unknown`. The
coordinator surfaces denial via `lastError` ("Auto-eject pending — Full Disk Access
required"), the menu bar shows a "Grant access" banner when auto-eject is ON +
denied, and a rate-limited (once per 24h) system notification fires.

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

### Defaults rationale: auto-eject is ON

The initial design (locked Architecture Decision #7) defaulted auto-eject to OFF. The
Step 12.7 design pass flipped it to ON per user request — TMEject's value prop is the
auto-eject; defaulting it OFF made the app feel inert on first run. The hourly-backup
trap is now mitigated only by the cooldown (default 30 min). Users running hourly TM
should raise the cooldown to 90+ min in Settings to avoid the next backup failing
because the drive ejected.

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

## Foreign TM drive detection

Use case: one Thunderbolt dock + multiple Macs sharing it. Plug the cable into
this Mac while another Mac's Time Machine drive is on the dock and macOS will
happily mount it. We want the wrong-Mac drive to auto-eject before Spotlight
starts indexing it or anything writes to it.

A drive is "foreign" iff BOTH:
1. It's a Time Machine drive (configured as a TM destination on SOME Mac).
2. It's NOT in this Mac's `tmutil destinationinfo -X` `MountPoint` set.

### "Is this a TM drive" — strategy A: APFS role check

Primary signal: `/usr/sbin/diskutil apfs list -plist` exposes a `Roles` array
on every APFS volume entry. A TM destination has `Roles = ["Backup"]`. We
parse the plist, build a `Set<String>` of BSD device identifiers (e.g.
`disk7s2`) whose role array contains `"Backup"`, and look up the new mount's
BSD name. Cache TTL is 30s; the cache is invalidated on every `DA` mount or
unmount event so it's fresh exactly when classification runs.

Notable: macOS does NOT expose APFS roles through DiskArbitration.
`kDADiskDescriptionVolumeApfsRolesKey` doesn't exist in the public framework,
and `DADiskCopyDescription`'s dict has no roles field (verified empirically on
macOS 26 Tahoe — see commit message of the introducing change). The
`diskutil apfs list -plist` shell-out is the cleanest path without private
SPI, runs as the user, and needs no FDA.

### Strategy B: filesystem-marker fallback

Some volumes won't be in the APFS plist (non-APFS, race during early mount).
For those, look for either marker at the volume root:

- `.com.apple.TimeMachine.IOCheck/` — present on APFS-era TM destinations
  even before the first backup completes.
- `Backups.backupdb/` — HFS+ legacy TM destinations.

`.MobileBackups` is deliberately NOT a marker — it's a SOURCE-side local
snapshots indicator, not a destination indicator.

### Fail-safe: classification unknown

If strategy A errored out (shell-out failed or plist unparseable) AND
strategy B found no markers, the classifier returns `.unknown`. The caller
(`DiskAppearedObserver`) treats that as "do nothing" — TMEject is in scope
for TM drives only, and we'd rather miss a foreign drive than risk ejecting
the user's primary external SSD. The unknown branch logs at ERROR so silent
classification failures surface.

Same fail-safe applies if `tmutil destinationinfo -X` fails: we can't tell
own-vs-foreign, so we skip ejection.

### 10-second grace + Cancel

On a confirmed foreign-TM detection, `ForeignDriveGracePeriod` schedules an
eject 10s in the future and surfaces a `.warning`-kind toast with a Cancel
button. Cancel paths: user click, drive yanked mid-grace, setting toggled
off. There's no per-UUID memory of cancels — same drive re-mounting fires
the grace again (the cable might come and go without intent).

Multiple concurrent grace timers are supported, keyed by `volumeURL`. A
duplicate `DADiskAppeared` callback for the same URL (DA emits one at
registration time) does NOT reset the running clock — startGrace is a no-op
when a pending entry already exists.

When the grace expires, the eject reuses `Ejector.eject(volumeURL:)` —
exactly the same DA unmount + 8-attempt retry schedule + lsof holder probe
as the post-backup auto-eject path. There's no state-machine entry; foreign
drives are independent of `AppState`.

### Default

`@AppStorage(ejectForeignTMDrives)` defaults TRUE — seeded at AppCoordinator
init the first time. The Settings → Behavior row offers a toggle. Off →
existing pending graces are cancelled with reason `.settingOff`.

## Observation: clocks

`MonotonicClock` (`ProcessInfo.systemUptime`) is used for the stall timer and
the confirming hard cap — both of which can run for hours. Wall-clock-based
timers would be vulnerable to NTP corrections during a long backup. The fake
clock in tests drives both timers deterministically.
