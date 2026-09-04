#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GUARD="$ROOT/module/bin/fcm_guard.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'acquire_guard_lock || exit 0' "$GUARD" \
  || fail "FCM guard is not serialized"
grep -q 'recent_gms_unknown_host_epoch' "$GUARD" \
  || fail "GMS UNKNOWN_HOST evidence is not inspected"
grep -q 'android_resolve_mtalk' "$GUARD" \
  || fail "Android resolver path is not checked"
grep -q 'flush_android_dns' "$GUARD" \
  || fail "DNS remediation is missing"
grep -q 'normalized Box FCM-only bypass' "$GUARD" \
  || fail "FCM bypass deduplication is missing"

unknown_line=$(grep -n 'GMS reported UNKNOWN_HOST' "$GUARD" | head -n1 | cut -d: -f1)
resolver_line=$(grep -n 'Android resolver cannot resolve mtalk.google.com' "$GUARD" | head -n1 | cut -d: -f1)
restart_line=$(grep -n 'kill -TERM "$gpid"' "$GUARD" | head -n1 | cut -d: -f1)
[ -n "$unknown_line" ] && [ -n "$resolver_line" ] && [ -n "$restart_line" ] \
  || fail "cannot locate DNS/restart policy branches"
[ "$unknown_line" -lt "$restart_line" ] \
  || fail "UNKNOWN_HOST gate must run before GMS restart"
[ "$resolver_line" -lt "$restart_line" ] \
  || fail "Android resolver gate must run before GMS restart"

kill_count=$(grep -c 'kill -TERM "$gpid"' "$GUARD" || true)
[ "$kill_count" -eq 1 ] \
  || fail "GMS SIGTERM must remain one explicit last-resort site"

# Regression for the actual event observed on the device:
# 16777984 packs connection_error=3 (UNKNOWN_HOST) in bits 8..15.
status=16777984
err=$(( (status / 256) % 256 ))
[ "$err" -eq 3 ] || fail "gtalk_connection UNKNOWN_HOST decoder regression"

echo "FCM guard policy regression checks passed"
