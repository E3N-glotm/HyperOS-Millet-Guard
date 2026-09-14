#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/bin/lib.sh"

SWIPE_CONFIG=$RUNDIR/swipe_keepalive.list
TXN_FILE=$RUNDIR/package_unstop.txn
TXN_FP_FILE=$RUNDIR/package_unstop.fingerprint
FRAMEWORK_JAR=/system/framework/framework.jar
DEXDUMP=/apex/com.android.art/bin/dexdump

swipe_managed() {
  pkg=$1
  normalize_file "$SWIPE_CONFIG" | grep -Fxq "$pkg"
}

package_is_stopped() {
  pkg=$1
  dumpsys package "$pkg" 2>/dev/null | grep -m1 'stopped=' | grep -q 'stopped=true'
}

discover_txn() {
  fp=$(getprop ro.build.fingerprint)
  if [ -f "$TXN_FILE" ] && [ -f "$TXN_FP_FILE" ] && [ "$(cat "$TXN_FP_FILE" 2>/dev/null)" = "$fp" ]; then
    txn=$(cat "$TXN_FILE" 2>/dev/null)
    case "$txn" in ''|*[!0-9]*) txn="" ;; esac
    if [ -n "$txn" ] && [ "$txn" -ge 1 ] 2>/dev/null && [ "$txn" -le 1000 ] 2>/dev/null; then
      printf '%s\n' "$txn"
      return 0
    fi
  fi

  [ -r "$FRAMEWORK_JAR" ] || return 1
  [ -x "$DEXDUMP" ] || return 1
  tmp=$RUNDIR/.ipm.$$.dex
  txn=""
  for dex in $("$BB" unzip -l "$FRAMEWORK_JAR" 2>/dev/null | awk '$4 ~ /^classes[0-9]*[.]dex$/ {print $4}'); do
    if "$BB" unzip -p "$FRAMEWORK_JAR" "$dex" 2>/dev/null | "$BB" strings 2>/dev/null | grep -q 'TRANSACTION_setPackageStoppedState'; then
      "$BB" unzip -p "$FRAMEWORK_JAR" "$dex" > "$tmp" 2>/dev/null || continue
      txn=$("$DEXDUMP" -d "$tmp" 2>/dev/null | awk '
        /name[[:space:]]*:[[:space:]]*'\''TRANSACTION_setPackageStoppedState'\''/ {found=1; next}
        found && $1=="value" && $2==":" {print $3; exit}
      ')
      rm -f "$tmp"
      case "$txn" in ''|*[!0-9]*) txn="" ;; esac
      [ -n "$txn" ] && break
    fi
  done
  rm -f "$tmp"

  [ -n "$txn" ] || return 1
  [ "$txn" -ge 1 ] 2>/dev/null && [ "$txn" -le 1000 ] 2>/dev/null || return 1

  printf '%s\n' "$txn" > "$TXN_FILE"
  printf '%s\n' "$fp" > "$TXN_FP_FILE"
  chmod 600 "$TXN_FILE" "$TXN_FP_FILE" 2>/dev/null || true
  log_msg "Swipe guard: discovered setPackageStoppedState transaction=$txn"
  printf '%s\n' "$txn"
}

pkg=$1
valid_pkg "$pkg" || exit 2
[ -f "$SWIPE_CONFIG" ] || exit 0
swipe_managed "$pkg" || exit 0

# This helper is invoked only for ActivityManager events whose reason is
# exactly SwipeUpClean. Generic app-info/shell/policy force-stops never reach
# this path and therefore retain normal Android stopped-package semantics.
package_is_stopped "$pkg" || exit 0

txn=$(discover_txn) || {
  log_msg "Swipe guard: cannot discover setPackageStoppedState transaction; pkg=$pkg left stopped"
  exit 1
}

out=$(service call package "$txn" s16 "$pkg" i32 0 i32 0 2>&1)
if package_is_stopped "$pkg"; then
  "$BB" sleep 0.15
  out2=$(service call package "$txn" s16 "$pkg" i32 0 i32 0 2>&1)
  out="$out | retry:$out2"
fi
if package_is_stopped "$pkg"; then
  log_msg "Swipe guard: failed to clear stopped state pkg=$pkg transaction=$txn result=$out"
  exit 1
fi

log_msg "Swipe guard: restored FCM eligibility after SwipeUpClean pkg=$pkg transaction=$txn"
exit 0
