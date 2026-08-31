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
- Permission-safe helper execution: v2.0.1 explicitly invokes internal helpers through `/system/bin/sh` and repairs helper execute bits at service startup, so GMS reconciliation still works if a ZIP extractor installs scripts as `0644`.
- No database fighting: PowerKeeper may still show `bgControl=miuiAuto`; the module works at the effective Millet/Greeze layer.
- Clean uninstall semantics.

## Requirements

- Rooted Xiaomi/Redmi/POCO device running a compatible HyperOS/MIUI build.
- Magisk-compatible module environment.
- `settings`, `dumpsys`, and BusyBox `inotifyd` available.

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

## Battery impact

The module itself is event-driven and normally sleeping. The low-frequency safety path runs once every 300 seconds.

**Important:** exempting an application from Millet/Greeze can increase that application's background activity and battery use. This is expected. Add only apps that genuinely need unrestricted background execution.

Do not confuse this with Android's DeviceIdle/Doze whitelist; they are separate policy layers.

## Security / privacy

- No network access.
- No telemetry.
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
