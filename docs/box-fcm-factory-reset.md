# Box/sing-box FCM setup after a factory reset

Millet Guard protects the HyperOS Millet/Greeze policy layer. It intentionally
does not rewrite another module's Box/sing-box configuration. For reliable FCM
on the setup validated by this project, the network layer should satisfy the
following invariants after every clean install or factory reset.

## 1. Use a dedicated FCM DNS path

The validated sing-box configuration has a DNS server tagged `fcm` and routes
`mtalk.google.com` through it. A representative server block is:

```json
{
  "type": "udp",
  "tag": "fcm",
  "server": "223.5.5.5"
}
```

The important property is that this resolver must not recurse back through the
same local DNS interception path. Use a resolver that is reachable directly on
every network you actually use. On 2026-09-11 the previously used
carrier-specific `61.139.2.69` resolver worked well on cellular but timed out on
the validated Wi-Fi path, while `223.5.5.5` worked directly during the incident
test. The address above is therefore representative, not universal. Do not pin
FCM to one carrier DNS without testing both Wi-Fi and cellular paths.

## 2. Route the FCM transport directly

The sing-box route should keep both the FCM domain and transport ports on the
direct path. Representative rules:

```json
{
  "network": "tcp",
  "port": [5228, 5229, 5230],
  "outbound": "direct"
},
{
  "domain_suffix": ["mtalk.google.com"],
  "outbound": "direct"
}
```

Adapt the JSON keys to the sing-box version/config schema you actually run.

## 3. Never hard-code the GMS UID

Android app UIDs are installation-state data. A factory reset can change the
UID of `com.google.android.gms`, so a restored `--uid-owner 10139` rule can
silently target the wrong application.

Resolve it whenever Box rebuilds its rules:

```sh
GMS_UID="$(pm list packages -U com.google.android.gms 2>/dev/null \
  | busybox awk '$1 == "package:com.google.android.gms" { sub(/^uid:/, "", $2); print $2; exit }')"
case "$GMS_UID" in
  ""|*[!0-9]*) GMS_UID="" ;;
esac
```

Millet Guard performs this lookup itself whenever its FCM guard runs. If
the tested `BOX_LOCAL` mangle chain exists, it checks for and restores only this
FCM-port bypass:

```sh
[ -n "$GMS_UID" ] && iptables -w 5 -t mangle -I BOX_LOCAL 1 \
  -p tcp -m owner --uid-owner "$GMS_UID" \
  -m tcp --dport 5228:5230 -j RETURN
```

v2.0.7 waits for the xtables lock before reading or writing this chain. If Box
itself owns the same exact FCM rule, the guard waits briefly for Box to finish a
rebuild before self-healing a genuinely missing rule. It no longer
deletes/reinserts duplicate live rules during normal checks, avoiding a race
with Box's own chain rebuild.

This means the validated TProxy setup does not depend on a persisted numeric UID
after a factory reset, and a later Box rule rebuild is repaired by the next FCM
guard pass. If your Box mode does not use a mangle `BOX_LOCAL` chain, Millet
Guard leaves it untouched; use the equivalent port-scoped rule required by
that mode. Do **not** add a blanket `--uid-owner "$GMS_UID" -j RETURN` rule:
Play Store/API traffic can keep using your normal proxy policy while only FCM's
long-lived transport is exempted.

## 4. Install Millet Guard after the network layer

Install the current Millet Guard ZIP and reboot. The default persistent package
list contains:

```text
com.google.android.gms
```

After boot, verify the policy layer:

```sh
settings get system MILLET_NO_RESTRICT_APP
dumpsys greezer | grep -m1 'mGmsLimitEnabled'
```

Expected: GMS is present in `MILLET_NO_RESTRICT_APP` and the Xiaomi GMS limiter
reports `false` on ROMs exposing the tested interface.

Verify FCM itself rather than relying on a third-party status UI:

```sh
dumpsys activity service com.google.android.gms/.gcm.GcmService \
  | grep -E -m1 -A12 'DeviceID:'
ss -ntp | grep -E '(:5228|:5229|:5230)'
```

Expected healthy state includes `Is client connected: true` (elsewhere in the
same GcmService dump) and normally an established mtalk socket. The GcmService
state is the authoritative signal used by Millet Guard; a missing 5228 socket
alone is not treated as failure because GMS can change transport behavior.

## 5. What v2.0.3 repairs automatically

Millet Guard can automatically repair the following module-side failures:

- Xiaomi removes GMS from the Millet no-restrict set;
- the Xiaomi GMS limiter is re-enabled;
- an interrupted reconciliation leaves a stale mutex;
- GcmService remains explicitly disconnected while a real mtalk DNS + TCP path
  is healthy, indicating a stuck GMS/MCS reconnect state.
- the tested Box/TProxy chain is rebuilt and loses the GMS FCM-port exception;
  the current GMS UID is rediscovered and the narrow rule is restored.

It cannot repair a genuinely unreachable carrier/Wi-Fi path or a sing-box
configuration that loops its own DNS. If you use the custom Box network monitor
from this project's validated setup, see `extras/box-for-root/net.inotify` for
the stale-lock/anti-loop hardened handler. Millet Guard deliberately does not
overwrite that third-party file automatically.
