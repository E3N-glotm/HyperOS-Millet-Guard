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
- Crash-safe reconciliation lock: v2.0.2 records the lock owner's PID plus `/proc` start time and automatically reaps stale/legacy locks instead of allowing one interrupted reconciliation to disable the guard indefinitely. v2.0.4 makes that validation proc-race-safe and removes the external `tr`/`cmdline` read that could spin a CPU core if the owner vanished mid-read on affected Toybox builds.
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

### v2.0.4 proc-race CPU fix

v2.0.4 hardens the stale-lock owner check after an observed HyperOS/Toybox failure where `reconcile.sh` opened `/proc/<pid>/cmdline`, the owner process exited, and Toybox `tr` then retried `read(2) = ESRCH` indefinitely. The orphaned `tr` process consumed about one CPU core until killed.

Lock identity now relies only on the already-stored owner PID plus `/proc/<pid>/stat` start-time ticks. The stat read is performed by the shell builtin rather than an external procfs reader, so a disappearing owner fails once and is treated as stale. No second `/proc/<pid>/cmdline` read is needed: PID plus start time already distinguishes a live process instance from PID reuse. CI includes a regression check that exercises the production lock helper functions and rejects reintroduction of the cmdline/`tr` path.

### v2.0.5 DNS-aware FCM recovery

v2.0.5 fixes a recovery-layer misclassification observed after a real MCS heartbeat timeout. Google Play services closed the stale connection and then reported `UNKNOWN_HOST` while reconnecting. The older guard could still resolve `mtalk.google.com` by sending a direct BusyBox `nslookup` to the configured upstream resolver, conclude that the network path was healthy, and repeatedly terminate `gms.persistent`. That direct probe did not exercise the same Android resolver path used by GMS, so restarting GMS could not repair the actual failure.

v2.0.5 added Android's libc/netd resolver path alongside the older direct upstream probe and also inspects recent `gtalk_connection` event-log status, decoding connection error `3` as `UNKNOWN_HOST`. A recent GMS `UNKNOWN_HOST` or a current Android resolver failure blocks every GMS restart. On Android versions where a real resolver cache flush API is available, Millet Guard may attempt it at a bounded rate; unsupported commands are now reported as such rather than counted as success. After a resolver failure clears, a 300-second stability grace prevents an immediate process restart. Starting with v2.0.7, the direct `nslookup` upstream probe is no longer treated as independent evidence because Box DNS hijacking can intercept that probe itself; TCP readiness is checked only after Android's own resolver has returned an address.

`fcm_guard.sh` is also serialized with an owner-validated lock because its two-minute poller and event-driven worker can run concurrently. This prevents duplicate recovery accounting and firewall mutations. The module records the currently managed GMS UID so an app-UID change can remove the old module-managed exception. v2.0.7 additionally waits for the xtables lock and avoids normal delete/reinsert duplicate normalization while Box may be rebuilding the same chain.

### v2.0.6 lost reconnect-alarm recovery

v2.0.6 fixes a second-stage failure observed on 2026-09-05. The MCS connection entered `UNKNOWN_HOST` at 05:00 and GMS retried normally several times, but after the last `GCM_RECONNECT` wakeup around 05:18 its internal `Reconnect Scheduler Alarm` stayed overdue while AlarmManager no longer contained a matching pending reconnect alarm. The device remained disconnected for nearly eight hours even after Android DNS later recovered. v2.0.5 correctly refused to churn GMS during the DNS failure, but it had no way to repair this lost scheduler state.

The guard now detects an overdue internal reconnect deadline (or a long-disconnected state with no pending `GCM_RECONNECT` alarm) and rate-limits a **soft reconnect** by broadcasting the same `com.google.android.intent.action.GCM_RECONNECT` event normally delivered by GMS's own AlarmManager PendingIntent. This does not terminate Play services. On the affected device, manually delivering that event recovered `mtalk.google.com:5228` within eight seconds while `gms.persistent` kept the same PID. DNS failures still block hard process restarts; the soft reconnect simply rebuilds Google's own reconnect/backoff state and is attempted at most once every five minutes while stalled.

### v2.0.7 xtables and DNS-path hardening

v2.0.7 fixes two additional failures found during a multi-day FCM/battery audit. First, `iptables -S BOX_LOCAL` could fail immediately while Android or Box held `/system/etc/xtables.lock`. Because stderr was discarded and the result was piped into `awk`, the old guard misread that transient lock failure as `count=0`, inserted a duplicate FCM rule, then later observed `count=2` and normalized it again. Box-chain reads and writes now use bounded `iptables -w`, read failures are fail-closed, and normal checks do not delete/reinsert duplicate live rules. If the installed Box script already owns the same narrow GMS rule, Millet Guard waits briefly for that native rebuild before self-healing a truly missing rule.

Second, Android 16 can return `500 0 Command not recognized` from `ndc resolver flushnet` while the `ndc` process itself exits with status `0`. v2.0.6 counted that as a successful resolver flush. v2.0.7 validates command output as well as the exit status and reports unsupported remediation instead of a false success. The FCM readiness probe also uses Android's own resolver result rather than a direct `nslookup` that may itself be intercepted by Box DNS hijacking.

The validated device additionally exposed a Box network-monitor stale lock and a carrier-specific FCM DNS single point. The hardened third-party handler is provided at `extras/box-for-root/net.inotify`: it recovers stale locks by PID/start-time, serializes before iptables mutation, and commits the stable network signature before a single Box restart so restart-generated route events cannot recurse. It is intentionally not auto-installed. The FCM DNS guidance now requires testing the selected resolver on both Wi-Fi and cellular rather than copying a carrier DNS address.

### v2.1.0 scope correction

v2.1.0 removes the experimental package stopped-state manipulation introduced
in v2.0.8/v2.0.9. Follow-up device forensics showed that the apparent new FCM
cold-start regression was caused by a previously enabled, dedicated HyperOS FCM
LSPosed compatibility module disappearing from the device during unrelated
LSPosed/Zygisk maintenance. After restoring that module, real HIGH-priority FCM
delivery to process-dead applications recovered without Millet Guard clearing
their package `stopped` state.

Millet Guard therefore returns to its original responsibility boundary: Millet/
Greeze no-restrict ownership, GMS limiter handling, FCM connection/network
recovery, and the narrow Box/iptables compatibility path. It no longer watches
`SwipeUpClean`, no longer calls `setPackageStoppedState()`, and does not attempt
to replace dedicated FCM cold-start compatibility modules. Explicit Android and
HyperOS package stop/autostart semantics are left untouched.

## Factory reset / clean-device setup

A factory reset removes Magisk modules and can assign Google Play services a different Android app UID. Do **not** restore a rule hard-coded to a previous UID such as `10139`.

For the same validated architecture on a clean device:

1. Root the device and install your Magisk-compatible environment.
2. Install/configure Box For Root and sing-box first.
3. Keep `mtalk.google.com` and TCP `5228-5230` on the direct FCM path; use a dedicated non-recursive FCM DNS resolver.
4. Keep the Box/TProxy `BOX_LOCAL` mangle chain available. Millet Guard resolves the current GMS UID itself, waits for xtables serialization, restores the exact TCP `5228-5230` exception only when genuinely missing, and removes its recorded old-UID exception after an app-UID change. Do not add a global GMS bypass.
5. Install the current Millet Guard release and reboot. Its default `packages.list` already contains `com.google.android.gms`.
6. Verify `MILLET_NO_RESTRICT_APP`, `mGmsLimitEnabled : false`, `GcmService connected=true`, and an established mtalk socket after boot and after a screen-off cycle.

The exact Box/sing-box snippets and verification commands are documented in [docs/box-fcm-factory-reset.md](docs/box-fcm-factory-reset.md).

## Battery impact

The Millet reconciliation path is event-driven and normally sleeping, with a five-minute safety check. v2.0.3 adds one sleeping two-minute FCM userspace fallback and one filtered `logcat` observer for existing GMS alarm deliveries. Neither creates an Android AlarmManager timer or acquires a wakelock. v2.0.4 also removes the procfs/Toybox lock-validation path that was observed to spin a CPU core after a narrow process-exit race. v2.0.5 serializes concurrent FCM checks and only starts resolver diagnostics after a sustained disconnect. In the healthy state the guard reads GCM service state, verifies/self-heals the narrow Box exception only if genuinely missing, and exits. A GMS process restart is strictly last-resort: Android resolver health, real TCP FCM reachability, absence of recent `UNKNOWN_HOST`, and resolver-stability grace must all pass first.

**Important:** exempting an application from Millet/Greeze can increase that application's background activity and battery use. This is expected. Add only apps that genuinely need unrestricted background execution.

Do not confuse this with Android's DeviceIdle/Doze whitelist; they are separate policy layers.

## Security / privacy

- No telemetry or remote control. The optional FCM recovery guard can inspect local Android event logs and issue `mtalk.google.com` resolver/readiness probes only after a confirmed disconnect; normal healthy checks do not perform external DNS probing.
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
