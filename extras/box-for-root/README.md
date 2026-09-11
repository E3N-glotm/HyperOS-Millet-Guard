# Box For Root compatibility patch

`net.inotify` is the hardened network-context handler used on the maintainer's
validated Box For Root + sing-box device. Millet Guard does **not** install this
file automatically because it belongs to another project and Box layouts vary.

The patch fixes two failure modes observed on the validated device:

1. a crashed handler left `/data/adb/box/run/net.heal.lock` behind forever;
2. `rules_add` ran before the old lock was acquired, so concurrent rtnetlink
   events could repeatedly churn iptables even while healing itself was locked.

The hardened handler uses PID + `/proc/<pid>/stat` start-time stale-lock
recovery, acquires the lock before any iptables mutation, debounces the event,
and commits the stable network signature **before** refreshing iptables or
restarting Box. That ordering prevents a Box restart from recursively treating
its own route/rule events as a new network change.

The replacement intentionally contains no direct `ip route` or `ip rule`
mutation. A failed Box restart leaves the observed state committed instead of
retrying on every rtnetlink event; this favors fail-safe behavior over a
possible restart storm.

Before replacing a live Box script, back up the original file and stop the
existing `net.monitor`/legacy `net.inotify` watchers. Initialize
`net.signature` to the current stable global IPv4 signature before restarting
Box once, then restart the watchers and verify that the sing-box PID remains
stable across subsequent self-generated route events.
