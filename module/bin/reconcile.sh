#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/bin/lib.sh"
LOCK=$RUNDIR/reconcile.lock
LOCK_OWNER=$LOCK/owner

proc_start_ticks() {
  pid=$1
  [ -r "/proc/$pid/stat" ] || return 1
  awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}

lock_owner_alive() {
  [ -r "$LOCK_OWNER" ] || return 1
  read -r owner_pid owner_start < "$LOCK_OWNER" 2>/dev/null || return 1
  case "$owner_pid:$owner_start" in
    ''|*[!0-9:]*|:*|*:) return 1 ;;
  esac
  current_start=$(proc_start_ticks "$owner_pid") || return 1
  [ "$current_start" = "$owner_start" ] || return 1
  cmdline=$(tr '\000' ' ' < "/proc/$owner_pid/cmdline" 2>/dev/null)
  case "$cmdline" in
    *gms_millet_guard/bin/reconcile.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

lock_age() {
  lock_mtime=$("$BB" stat -c %Y "$LOCK" 2>/dev/null)
  now=$(date +%s)
  case "$lock_mtime:$now" in
    *[!0-9:]*|:*|*:) echo 0 ;;
    *) echo $((now-lock_mtime)) ;;
  esac
}

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    start=$(proc_start_ticks $$)
    [ -n "$start" ] || start=0
    printf '%s %s\n' "$$" "$start" > "$LOCK_OWNER"
    return 0
  fi

  # A live owner means another reconciliation is legitimately in flight.
  lock_owner_alive && return 1

  # Older releases created an ownerless directory. Avoid racing a process
  # between mkdir() and writing owner metadata: only reap ownerless locks once
  # they have been stale for at least 30 seconds.
  age=$(lock_age)
  [ "$age" -ge 30 ] 2>/dev/null || return 1
  log_msg "reconcile[$1]: recovering stale lock age=${age}s"
  rm -rf "$LOCK" 2>/dev/null || return 1

  if mkdir "$LOCK" 2>/dev/null; then
    start=$(proc_start_ticks $$)
    [ -n "$start" ] || start=0
    printf '%s %s\n' "$$" "$start" > "$LOCK_OWNER"
    return 0
  fi
  return 1
}

release_lock() {
  [ -r "$LOCK_OWNER" ] || return 0
  read -r owner_pid owner_start < "$LOCK_OWNER" 2>/dev/null || return 0
  [ "$owner_pid" = "$$" ] || return 0
  rm -rf "$LOCK" 2>/dev/null || true
}

acquire_lock "$1" || exit 0
trap 'release_lock' EXIT HUP INT TERM
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
cleanup() {
  rm -f "$TMPBASE" "$TMPDES" "$TMPOWN" "$TMPNEW" 2>/dev/null || true
  release_lock
}
trap 'cleanup' EXIT HUP INT TERM
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
