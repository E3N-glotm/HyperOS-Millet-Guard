#!/system/bin/sh

set -u

BOX_DIR=/data/adb/box
TARGET="$BOX_DIR/scripts/net.inotify"
MONITOR="$BOX_DIR/scripts/net.monitor"
RUN="$BOX_DIR/run"

fail=0

check() {
  label=$1
  result=$2
  if [ "$result" = "PASS" ]; then
    echo "PASS: $label"
  else
    echo "FAIL: $label"
    fail=1
  fi
}

[ "$(id -u)" = "0" ] || {
  echo "ERROR: run as root (su)" >&2
  exit 1
}

if /system/bin/sh -n "$TARGET" >/dev/null 2>&1; then
  check "installed net.inotify syntax" PASS
else
  check "installed net.inotify syntax" FAIL
fi

INOTIFY_COUNT=$(ps -A -o ARGS 2>/dev/null | grep -F "inotifyd $TARGET /data/misc/net" | grep -v grep | wc -l | tr -d ' ')
MONITOR_COUNT=$(ps -A -o ARGS 2>/dev/null | grep -F "sh $MONITOR" | grep -v grep | wc -l | tr -d ' ')
[ "$INOTIFY_COUNT" = "1" ] && check "exactly one net.inotify watcher" PASS || check "exactly one net.inotify watcher (found $INOTIFY_COUNT)" FAIL

# net.monitor uses `ip monitor ... | while ...`, so Android normally shows a
# parent shell plus a pipeline child with the same argv. The parent PID written
# by net.monitor itself is the authoritative singleton identity.
MONITOR_PID=$(cat "$RUN/net.monitor.pid" 2>/dev/null || true)
monitor_ok=0
case "$MONITOR_PID" in
  ''|*[!0-9]*) MONITOR_PID= ;;
esac
if [ -n "$MONITOR_PID" ] && [ -r "/proc/$MONITOR_PID/cmdline" ]; then
  monitor_cmd=$(tr '\0' ' ' < "/proc/$MONITOR_PID/cmdline" 2>/dev/null || true)
  case "$monitor_cmd" in
    *"sh $MONITOR"*) monitor_ok=1 ;;
  esac
fi
[ "$monitor_ok" -eq 1 ] \
  && check "net.monitor parent from pidfile is alive (pid=$MONITOR_PID; ps rows=$MONITOR_COUNT)" PASS \
  || check "net.monitor parent from pidfile is alive (pid=$MONITOR_PID; ps rows=$MONITOR_COUNT)" FAIL

if [ -d "$RUN/net.heal.lock" ]; then
  check "no stale net.heal.lock" FAIL
else
  check "no stale net.heal.lock" PASS
fi

SIG=$(cat "$RUN/net.signature" 2>/dev/null || true)
[ -n "$SIG" ] && [ "$SIG" != "__offline__" ] \
  && check "network signature initialized ($SIG)" PASS \
  || check "network signature initialized ($SIG)" FAIL

SINGBOX_PID=$(pidof sing-box 2>/dev/null || true)
[ -n "$SINGBOX_PID" ] && check "sing-box running (pid=$SINGBOX_PID)" PASS || check "sing-box running" FAIL

echo "Recent compatibility events:"
grep -E 'stable network context|network-context refresh|restart suppressed|recovering stale network-context lock' "$RUN/net.log" 2>/dev/null | tail -10 || true

exit "$fail"

