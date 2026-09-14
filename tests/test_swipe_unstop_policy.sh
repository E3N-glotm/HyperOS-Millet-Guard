#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORKER="$ROOT/module/bin/fcm_event_worker.sh"
HELPER="$ROOT/module/bin/swipe_unstop.sh"
CTL="$ROOT/module/bin/milletctl"
SERVICE="$ROOT/module/service.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$HELPER" ] || fail "SwipeUpClean helper is missing"
grep -q 'Force stopping .*: SwipeUpClean' "$WORKER" \
  || fail "event worker does not filter exact SwipeUpClean force-stop events"
grep -q 'ActivityManager:I' "$WORKER" \
  || fail "event worker is not subscribed to ActivityManager"
grep -q 'logcat -b main -b system' "$WORKER" \
  || fail "event worker must read the system buffer where HyperOS logs SwipeUpClean"
grep -q 'swipe_unstop.sh' "$WORKER" \
  || fail "event worker does not call the swipe helper"
if grep -qE 'OneKeyClean|from pid|force-stop package' "$WORKER"; then
  fail "worker must not widen protection to generic/one-key force-stops"
fi

grep -q 'TRANSACTION_setPackageStoppedState' "$HELPER" \
  || fail "helper does not discover the stopped-state binder transaction"
grep -q 'ro.build.fingerprint' "$HELPER" \
  || fail "transaction cache is not scoped to the current build fingerprint"
grep -q 'service call package "$txn" s16 "$pkg" i32 0 i32 0' "$HELPER" \
  || fail "helper does not clear only the stopped state"
grep -q 'package_is_stopped "$pkg"' "$HELPER" \
  || fail "helper does not verify package stopped state"
grep -q 'swipe_keepalive.list' "$HELPER" \
  || fail "helper is not opt-in"

grep -q 'swipe-add <package.name>' "$CTL" \
  || fail "milletctl does not expose swipe protection configuration"
grep -q 'swipe_keepalive.list' "$SERVICE" \
  || fail "service does not initialize the opt-in swipe list"

echo "SwipeUpClean protection policy regression checks passed"
