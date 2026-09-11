#!/system/bin/sh

set -u

BOX_DIR=/data/adb/box
SCRIPTS="$BOX_DIR/scripts"
RUN="$BOX_DIR/run"
TARGET="$SCRIPTS/net.inotify"
MONITOR="$SCRIPTS/net.monitor"
SERVICE="$SCRIPTS/box.service"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

find_busybox() {
  for candidate in /data/adb/magisk/busybox /system/xbin/busybox /data/adb/ksu/bin/busybox; do
    [ -x "$candidate" ] && {
      echo "$candidate"
      return 0
    }
  done
  command -v busybox 2>/dev/null || return 1
}

matching_pids() {
  pattern=$1
  ps -A -o PID,ARGS 2>/dev/null | "$BB" awk -v p="$pattern" 'index($0,p) {print $1}'
}

stop_watchers() {
  for pid in $(matching_pids "inotifyd $TARGET /data/misc/net"); do kill "$pid" 2>/dev/null || true; done
  for pid in $(matching_pids "sh $MONITOR"); do kill "$pid" 2>/dev/null || true; done
  sleep 1
}

start_watchers() {
  monitor_alive=0
  monitor_pid=$(cat "$RUN/net.monitor.pid" 2>/dev/null || true)
  case "$monitor_pid" in
    ''|*[!0-9]*) monitor_pid= ;;
  esac
  if [ -n "$monitor_pid" ] && [ -r "/proc/$monitor_pid/cmdline" ]; then
    monitor_cmd=$("$BB" tr '\0' ' ' < "/proc/$monitor_pid/cmdline" 2>/dev/null || true)
    case "$monitor_cmd" in
      *"sh $MONITOR"*) monitor_alive=1 ;;
    esac
  fi
  if [ -x "$MONITOR" ] && [ "$monitor_alive" -eq 0 ]; then
    /system/bin/sh "$MONITOR" >/dev/null 2>&1 &
  fi
  if ! ps -A -o ARGS 2>/dev/null | grep -Fq "inotifyd $TARGET /data/misc/net"; then
    "$BB" inotifyd "$TARGET" /data/misc/net >/dev/null 2>&1 &
  fi
}

[ "$(id -u)" = "0" ] || die "run as root (su)"
BB=$(find_busybox) || die "BusyBox not found"

BACKUP=${1:-}
if [ -z "$BACKUP" ] || [ "$BACKUP" = "latest" ]; then
  BACKUP=$(cat "$RUN/net-context-compat.last-backup" 2>/dev/null || true)
fi
[ -n "$BACKUP" ] || die "backup path not supplied and no latest backup recorded"
[ -d "$BACKUP" ] || die "backup directory not found: $BACKUP"
[ -f "$BACKUP/net.inotify" ] || die "backup does not contain original net.inotify: $BACKUP"

echo "Restoring from: $BACKUP"
stop_watchers
cp -p "$BACKUP/net.inotify" "$TARGET" || die "failed to restore original handler"

for name in net.signature net.default_error.count net.heal.epoch; do
  if [ -f "$BACKUP/$name" ]; then
    cp -p "$BACKUP/$name" "$RUN/$name"
  else
    rm -f "$RUN/$name"
  fi
done
rm -rf "$RUN/net.heal.lock"

"$SERVICE" restart > "$RUN/net-context-compat-rollback.log" 2>&1 \
  || die "Box restart after rollback failed; inspect $RUN/net-context-compat-rollback.log"
start_watchers
sleep 2
echo "Rollback completed."

