#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/bin/lib.sh"
LOCK=$RUNDIR/reconcile.lock
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
[ -f "$CONFIG" ] || {
  cat > "$CONFIG" <<'LIST'
# Millet Guard managed packages, one per line.
com.google.android.gms
LIST
  chmod 600 "$CONFIG"
}
TMPBASE=$RUNDIR/.base.$$
TMPDES=$RUNDIR/.desired.$$
TMPOWN=$RUNDIR/.owned.$$
TMPNEW=$RUNDIR/.new.$$
trap 'rm -f "$TMPBASE" "$TMPDES" "$TMPOWN" "$TMPNEW"; rmdir "$LOCK" 2>/dev/null' EXIT
managed_list > "$TMPDES"
owned_list > "$TMPOWN"
# Ownership-aware merge:
#   base = effective setting - entries managed by us on the previous run
#   new  = base + current desired managed entries
# This preserves external/system entries while allowing users to REMOVE apps
# from packages.list without stale entries being resurrected.
setting_list | while IFS= read -r pkg; do
  if ! grep -Fxq "$pkg" "$TMPOWN" 2>/dev/null; then
    printf '%s\n' "$pkg"
  fi
done > "$TMPBASE"
cat "$TMPBASE" "$TMPDES" | sed '/^$/d' | awk '!seen[$0]++' > "$TMPNEW"
current=$(setting_list | join_csv)
desired=$(cat "$TMPNEW" | join_csv)
if [ "$current" != "$desired" ]; then
  if [ -n "$desired" ]; then
    settings --user 0 put system MILLET_NO_RESTRICT_APP "$desired" >/dev/null 2>&1
  else
    settings --user 0 delete system MILLET_NO_RESTRICT_APP >/dev/null 2>&1
  fi
  verify=$(setting_list | join_csv)
  if [ "$verify" = "$desired" ]; then
    log_msg "reconciled[$1]: $verify"
  else
    log_msg "ERROR reconcile[$1] expected='$desired' got='$verify'"
  fi
fi
cp -f "$TMPDES" "$OWNED"
chmod 600 "$OWNED" 2>/dev/null
# GMS has a second Xiaomi-specific limiter in addition to the generic set.
# Only touch it when GMS is explicitly managed by the user.
if grep -Fxq 'com.google.android.gms' "$TMPDES"; then
  now=$(date +%s)
  sspid=$(pidof system_server 2>/dev/null | awk '{print $1}')
  lastpid=$(cat "$RUNDIR/system_server.pid" 2>/dev/null)
  lastcheck=$(cat "$RUNDIR/limiter_check.epoch" 2>/dev/null)
  [ -n "$lastcheck" ] || lastcheck=0
  need=0
  [ -n "$sspid" ] && [ "$sspid" != "$lastpid" ] && need=1
  [ $((now-lastcheck)) -ge 300 ] 2>/dev/null && need=1
  if [ "$need" = "1" ]; then
    state=$(run_timeout dumpsys greezer 2>/dev/null | grep -m1 'mGmsLimitEnabled' || true)
    case "$state" in
      *true*|"")
        run_timeout dumpsys greezer IM GMS disable >/dev/null 2>&1 || true
        state2=$(run_timeout dumpsys greezer 2>/dev/null | grep -m1 'mGmsLimitEnabled' || true)
        log_msg "GMS limiter check: ${state2:-unavailable}"
        ;;
    esac
    [ -n "$sspid" ] && echo "$sspid" > "$RUNDIR/system_server.pid"
    echo "$now" > "$RUNDIR/limiter_check.epoch"
  fi
  /system/bin/sh "$MODDIR/bin/fcm_guard.sh" "$1" >/dev/null 2>&1 || true
fi
