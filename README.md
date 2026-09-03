# HyperOS Millet Guard

A small Magisk module for Xiaomi/HyperOS that persistently keeps **user-selected applications** in `Settings.System.MILLET_NO_RESTRICT_APP`, while leaving Millet/Greeze globally enabled.

This project grew out of a Google Play services / FCM reliability fix, but v2 is generic: users can manage any Android package name.

## Why

On some HyperOS builds, PowerKeeper/Millet/Greeze may quick-freeze apps even when Android's ordinary Doze/DeviceIdle policy would otherwise allow background work. For Google Play services this can delay FCM recovery; other apps may have similar use cases.

Millet Guard does **not** disable Millet/Greeze globally. It maintains a narrow, user-controlled no-restrict set.

## Features

- Configurable package list; one package per line.
- Event-driven reconciliation using `inotifyd` on SettingsProvider files.
- 5-minute low-frequency safety check for missed events/runtime policy changes.
- Ownership-aware state: removing an app from the config removes only the entry that Millet Guard previously owned.
- Preserves unrelated entries created by the system, user, HyperCeiler, PowerKeeper, or other modules.
- Special GMS handling: when `com.google.android.gms` is managed, the known Xiaomi GMS limiter is disabled on a best-effort basis.
- Path-aware FCM recovery guard for the tested sing-box/Box setup: it reads GMS's own `GcmService` connection state, waits five minutes for Google's native reconnect, verifies real `mtalk.google.com` DNS **and TCP/5228-5230 reachability**, then resets only a genuinely stuck `com.google.android.gms.persistent` reconnect state.
- FCM recovery is independent of Settings reconciliation in v2.0.3. A two-minute userspace fallback plus an event worker that piggybacks on GMS/HyperOS alarm deliveries prevents a reconciliation failure from disabling push recovery, without adding a new Android alarm or wakelock.
- On the tested Box/TProxy stack, v2.0.3 also self-heals one UID-scoped **FCM-port-only** `BOX_LOCAL` bypass. The GMS UID is resolved dynamically, so a factory reset cannot leave the module targeting an old hard-coded UID.
- Permission-safe helper execution: v2.0.1 explicitly invokes internal helpers through `/system/bin/sh` and repairs helper execute bits at service startup, so GMS reconciliation still works if a ZIP extractor installs scripts as `0644`.
- Crash-safe reconciliation lock: v2.0.2 records the lock owner's PID plus `/proc` start time and automatically reaps stale/legacy locks instead of allowing one interrupted reconciliation to disable the guard indefinitely.
- No database fighting: PowerKeeper may still show `bgControl=miuiAuto`; the module works at the effective Millet/Greeze layer.
- Clean uninstall semantics.

## Requirements

- Rooted Xiaomi/Redmi/POCO device running a compatible HyperOS/MIUI build.
- Magisk-compatible module environment.
- `settings`, `dumpsys`, and BusyBox `inotifyd` available.

The optional FCM recovery guard is deliberately narrower than the core Millet feature. It activates only when `com.google.android.gms` is managed **and** a `sing-box` process is present. It does not install Box For Root or rewrite a user's sing-box configuration. If a compatible `BOX_LOCAL` mangle chain exists, it may maintain one narrow TCP `5228-5230` RETURN rule for the dynamically resolved GMS UID; it never creates a blanket GMS bypass.

The internal Xiaomi APIs used here are undocumented and can change between ROM versions. Test on your own device.

## Configuration

Persistent config:

```text
/data/adb/millet_guard/packages.list
```

Default:

```text
com.google.android.gms
```

Blank lines and `# comments` are ignored.

Example:

```text
# Messaging
com.tencent.mm
org.telegram.messenger

# Google push stack
com.google.android.gms
```

After editing:

```sh
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl apply'
```

## CLI

```sh
# List managed packages
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl list'

# Add an app
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl add com.tencent.mm'

# Remove an app
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl remove com.tencent.mm'

# Show effective state
su -c '/data/adb/modules/gms_millet_guard/bin/milletctl status'
```

The Magisk **Action** button is read-only/diagnostic apart from running one idempotent reconciliation.

## How ownership works

Millet Guard tracks the entries it managed on the previous run in:

```text
/data/adb/millet_guard/managed.last
```

Reconciliation is effectively:

```text
base = current MILLET_NO_RESTRICT_APP - previous_module_owned_entries
new  = base + current packages.list
```

This avoids two common bugs:

1. removing an app from the config but having it remain permanently no-restrict;
2. overwriting unrelated no-restrict entries created by the system or other tools.

## Google Play services special case

`com.google.android.gms` has an additional Xiaomi-specific limiter (`mGmsLimitEnabled`) on the tested HyperOS build. If GMS is present in `packages.list`, Millet Guard periodically performs the already-observed hidden command:

```sh
dumpsys greezer IM GMS disable
```

The generic `MILLET_NO_RESTRICT_APP` mechanism remains the primary feature. This GMS command is best-effort and ROM-specific.

### v2.0.1 reliability fix

v2.0.1 fixes a failure mode where helper scripts could be extracted without executable bits. In that state the Xiaomi GMS command itself was valid, but the module's direct helper invocation could fail with `Permission denied` before reconciliation reached it. Installation now assigns explicit script modes, service startup self-heals the helper modes, and internal helper chaining uses `/system/bin/sh`.

### v2.0.2 stale-lock recovery

v2.0.2 fixes a second failure mode observed after a `SettingsProvider`/`system_server` interruption. Older releases used a bare `mkdir` directory as the reconciliation mutex. If that shell was killed before its `EXIT` trap ran, `/data/adb/millet_guard/reconcile.lock` could remain forever; every later safety/inotify pass then exited immediately, so the GMS whitelist, Xiaomi limiter disable, and FCM recovery guard all silently stopped running.

The lock now stores the owning shell PID and that process's `/proc/<pid>/stat` start time. A later pass keeps the lock only when both still identify a live Millet Guard reconciliation process. Dead or PID-reused owners are reclaimed automatically, and ownerless locks from v2.0.1 are recovered after a short anti-race grace period. Service startup also removes the legacy ownerless lock before the first boot reconciliation.

### v2.0.3 faster, path-aware FCM recovery

The current source tree also contains the FCM recovery logic validated on the maintainer's HyperOS + Box/sing-box setup. It does **not** treat a missing TCP/5228 socket as proof of failure, because Google Play services may legitimately fall back to TCP/443. Instead it queries:

```text
dumpsys activity service com.google.android.gms/.gcm.GcmService
```

and uses `Is client connected: true/false` as the authoritative runtime signal. On a normal connection it immediately exits. On an explicit disconnect it first allows Google's own reconnect logic to work for five minutes. It then resolves `mtalk.google.com` and performs a real TCP probe against ports `5228`, `5229`, and `5230`. Only if that FCM path is reachable, `sing-box` and `gms.persistent` are both running, and GCM remains disconnected does it terminate the persistent GMS process so Android can relaunch it with a fresh reconnect state.

The early retry schedule is now 5, 10, 20, 30, 30 minutes and then a 60-minute cap between later interventions. This is intentionally much faster than v2.0.2's 30/60/120-minute backoff, which was observed to turn one stuck MCS state into an approximately four-hour push outage. If the real mtalk TCP path is unavailable, Millet Guard does **not** churn GMS; it logs that condition at most once every 15 minutes and waits for the network to recover.

The guard is no longer called only from `reconcile.sh`. A dedicated low-frequency worker checks every two minutes while userspace is running, and `fcm_event_worker.sh` observes existing HyperOS Whetstone/GMS AlarmManager deliveries and checks FCM when the system has already woken Google Play services. The event path creates no extra Android alarm and acquires no wakelock. Android deep suspend may still defer the shell fallback, so the five-minute threshold is a policy threshold rather than a hard wall-clock SLA during complete suspend.

The helper does not rewrite sing-box JSON. On the validated device, `mtalk.google.com` / Google FCM DNS is separately routed through a dedicated resolver in sing-box. For the tested Box/TProxy layout, v2.0.3 additionally checks whether the `BOX_LOCAL` mangle chain exists and self-heals one **UID-scoped, FCM-port-only** TCP `5228-5230` RETURN rule using the GMS UID discovered from the current install. It intentionally does not create a blanket GMS bypass or mutate arbitrary Box configuration files. See [docs/box-fcm-factory-reset.md](docs/box-fcm-factory-reset.md) for the reproducible network prerequisites.

## Factory reset / clean-device setup

A factory reset removes Magisk modules and can assign Google Play services a different Android app UID. Do **not** restore a rule hard-coded to a previous UID such as `10139`.

For the same validated architecture on a clean device:

1. Root the device and install your Magisk-compatible environment.
2. Install/configure Box For Root and sing-box first.
3. Keep `mtalk.google.com` and TCP `5228-5230` on the direct FCM path; use a dedicated non-recursive FCM DNS resolver.
4. Keep the Box/TProxy `BOX_LOCAL` mangle chain available. Millet Guard v2.0.3 resolves the current GMS UID itself and restores **only** the TCP `5228-5230` exception if Box rebuilds the chain. Do not add a global GMS bypass.
5. Install Millet Guard v2.0.3 and reboot. Its default `packages.list` already contains `com.google.android.gms`.
6. Verify `MILLET_NO_RESTRICT_APP`, `mGmsLimitEnabled : false`, `GcmService connected=true`, and an established mtalk socket after boot and after a screen-off cycle.

The exact Box/sing-box snippets and verification commands are documented in [docs/box-fcm-factory-reset.md](docs/box-fcm-factory-reset.md).

## Battery impact

The Millet reconciliation path is event-driven and normally sleeping, with a five-minute safety check. v2.0.3 adds one sleeping two-minute FCM userspace fallback and one filtered `logcat` observer for existing GMS alarm deliveries. Neither creates an Android AlarmManager timer or acquires a wakelock. In the healthy state the guard only reads GCM service state and exits; DNS/TCP probes happen only after a confirmed disconnect has exceeded the recovery grace period. A GMS process restart is reserved for the abnormal path-aware disconnect case described above.

**Important:** exempting an application from Millet/Greeze can increase that application's background activity and battery use. This is expected. Add only apps that genuinely need unrestricted background execution.

Do not confuse this with Android's DeviceIdle/Doze whitelist; they are separate policy layers.

## Security / privacy

- No telemetry or remote control. The optional FCM recovery guard can issue a single `mtalk.google.com` DNS readiness probe after a confirmed long disconnect; normal healthy checks do not perform that probe.
- No bundled binaries.
- No modification of PowerKeeper databases.
- No global disabling of Millet/Greeze.

## Uninstall

Uninstalling the module removes only the effective whitelist entries last owned by Millet Guard. The persistent package list is retained at `/data/adb/millet_guard/packages.list` so reinstalling preserves the user's choices.

For a full purge:

```sh
rm -rf /data/adb/millet_guard
```

## Compatibility note

This project relies on reverse-engineered Xiaomi implementation details. `MILLET_NO_RESTRICT_APP`, Greeze commands, and behavior may differ across ROM versions. Issues should include device model, HyperOS/MIUI version, Android version, and the output of the Action diagnostics, with personal data removed.

## License

MIT
