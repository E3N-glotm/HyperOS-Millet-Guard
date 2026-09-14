#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORKER="$ROOT/module/bin/fcm_event_worker.sh"
CTL="$ROOT/module/bin/milletctl"
SERVICE="$ROOT/module/service.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ ! -e "$ROOT/module/bin/swipe_unstop.sh" ] \
  || fail "SwipeUpClean stopped-state helper must not be shipped"
[ ! -e "$ROOT/tests/test_swipe_unstop_policy.sh" ] \
  || fail "obsolete SwipeUpClean regression test must not be shipped"

grep -q "--regex='sourcePkg=com.google.android.gms'" "$WORKER" \
  || fail "event worker must stay scoped to GMS alarm events"
grep -q "logcat -b main" "$WORKER" \
  || fail "event worker must observe the existing Whetstone main-buffer path"

for file in "$WORKER" "$CTL" "$SERVICE"; do
  if grep -qE 'SwipeUpClean|swipe_keepalive|swipe_unstop|swipe-add|swipe-remove|swipe-list|swipe-config' "$file"; then
    fail "package stopped-state manipulation leaked back into $file"
  fi
done

echo "Module scope regression checks passed"
