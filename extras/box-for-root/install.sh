#!/system/bin/sh

set -u

BOX_DIR=/data/adb/box
SCRIPTS="$BOX_DIR/scripts"
RUN="$BOX_DIR/run"
TARGET="$SCRIPTS/net.inotify"
MONITOR="$SCRIPTS/net.monitor"
SERVICE="$SCRIPTS/box.service"
PATCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$PATCH_DIR/net.inotify"

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

network_signature() {
  ip -4 -o addr show scope global up 2>/dev/null \
    | "$BB" awk '{print $2 "=" $4}' \
    | "$BB" sort \
    | "$BB" tr '\n' ';'
}

matching_pids() {
  pattern=$1
  ps -A -o PID,ARGS 2>/dev/null \
    | "$BB" awk -v p="$pattern" 'index($0,p) {print $1}'
}

stop_watchers() {
  for pid in $(matching_pids "inotifyd $TARGET /data/misc/net"); do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $(matching_pids "sh $MONITOR"); do
    kill "$pid" 2>/dev/null || true
  done
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

restore_state_file() {
  name=$1
  if [ -f "$BACKUP/$name" ]; then
    cp -p "$BACKUP/$name" "$RUN/$name"
  else
    rm -f "$RUN/$name"
  fi
}

[ "$(id -u)" = "0" ] || die "run as root (su)"
[ -d "$SCRIPTS" ] || die "Box For Root scripts directory not found: $SCRIPTS"
[ -x "$SERVICE" ] || die "Box service script not executable: $SERVICE"
[ -f "$TARGET" ] || die "existing Box net.inotify not found: $TARGET"
[ -f "$SOURCE" ] || die "compatibility handler not found beside installer: $SOURCE"
/system/bin/sh -n "$SOURCE" || die "net.inotify syntax check failed"

BB=$(find_busybox) || die "BusyBox not found"
mkdir -p "$RUN" "$BOX_DIR/backups" || die "cannot create Box runtime/backup directories"

if [ "${1:-}" = "--check" ]; then
  echo "PRECHECK PASS"
  echo "Box service: $SERVICE"
  echo "Existing handler: $TARGET"
  echo "Compatibility handler: $SOURCE"
  echo "BusyBox: $BB"
  echo "Current signature: $(network_signature)"
  echo "No files, processes, iptables rules, or services were modified."
  exit 0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BOX_DIR/backups/net-context-compat-$STAMP"
mkdir -p "$BACKUP" || die "cannot create backup: $BACKUP"

[ -f "$TARGET" ] && cp -p "$TARGET" "$BACKUP/net.inotify"
for name in net.signature net.default_error.count net.heal.epoch; do
  [ -f "$RUN/$name" ] && cp -p "$RUN/$name" "$BACKUP/$name"
done
printf '%s\n' "$BACKUP" > "$RUN/net-context-compat.last-backup"

echo "Backup: $BACKUP"
stop_watchers

TMP="$TARGET.compat.$$"
cp "$SOURCE" "$TMP" || die "cannot stage handler"
chmod 0755 "$TMP" || die "cannot chmod staged handler"
/system/bin/sh -n "$TMP" || die "staged handler syntax check failed"
mv "$TMP" "$TARGET" || die "cannot install handler"

# Remove only the compatibility handler's stale serialization directory.
rm -rf "$RUN/net.heal.lock"

SIG=$(network_signature)
if [ -n "$SIG" ]; then
  printf '%s\n' "$SIG" > "$RUN/net.signature"
else
  printf '%s\n' '__offline__' > "$RUN/net.signature"
fi
printf '%s\n' 0 > "$RUN/net.default_error.count"
date +%s > "$RUN/net.heal.epoch"

LOG="$RUN/net-context-compat-install.log"
if ! "$SERVICE" restart > "$LOG" 2>&1; then
  echo "Box restart failed; restoring original handler and state" >&2
  if [ -f "$BACKUP/net.inotify" ]; then
    cp -p "$BACKUP/net.inotify" "$TARGET"
  fi
  restore_state_file net.signature
  restore_state_file net.default_error.count
  restore_state_file net.heal.epoch
  rm -rf "$RUN/net.heal.lock"
  "$SERVICE" restart >> "$LOG" 2>&1 || true
  start_watchers
  die "install rolled back; inspect $LOG"
fi

start_watchers
sleep 3

INOTIFY_COUNT=$(ps -A -o ARGS 2>/dev/null | grep -F "inotifyd $TARGET /data/misc/net" | grep -v grep | wc -l | tr -d ' ')
MONITOR_PID=$(cat "$RUN/net.monitor.pid" 2>/dev/null || true)

echo "Installed: $TARGET"
echo "Signature: $(cat "$RUN/net.signature" 2>/dev/null)"
echo "Watchers: net.inotify=$INOTIFY_COUNT net.monitor_parent=$MONITOR_PID"
echo "Rollback backup: $BACKUP"
echo "Run: su -c 'sh $PATCH_DIR/verify.sh'"

