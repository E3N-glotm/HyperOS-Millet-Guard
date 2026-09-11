#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HANDLER="$ROOT/extras/box-for-root/net.inotify"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'proc_start_ticks' "$HANDLER" || fail "stale-lock PID/start-time validation is missing"
grep -q 'recovering stale network-context lock' "$HANDLER" || fail "stale network lock recovery is missing"
grep -q 'restart_cooldown=15' "$HANDLER" || fail "restart cooldown is missing"
grep -q 'acquire_net_lock || exit 0' "$HANDLER" || fail "network handler is not serialized"
grep -q 'Commit the state BEFORE any operation' "$HANDLER" || fail "loop-breaker state commit is not documented"
grep -q 'if \[ "$signature_changed" -eq 0 \]' "$HANDLER" \
  || fail "restart cooldown must not suppress a genuine new network signature"

main_lock=$(grep -n 'acquire_net_lock || exit 0' "$HANDLER" | tail -n1 | cut -d: -f1)
main_rules=$(grep -n '^  rules_add$' "$HANDLER" | tail -n1 | cut -d: -f1)
state_commit=$(grep -n 'atomic_write "$state_file" "$stable_signature"' "$HANDLER" | tail -n1 | cut -d: -f1)
restart=$(grep -n '^"$service_path" restart' "$HANDLER" | tail -n1 | cut -d: -f1)

[ -n "$main_lock" ] && [ -n "$main_rules" ] && [ "$main_lock" -lt "$main_rules" ] \
  || fail "lock must be acquired before rules_add"
[ -n "$state_commit" ] && [ -n "$restart" ] && [ "$state_commit" -lt "$restart" ] \
  || fail "network signature must be committed before Box restart"

if grep -Eq 'ip[[:space:]]+(route|rule)[[:space:]]+(add|del|flush|replace)' "$HANDLER"; then
  fail "handler must not mutate routes/rules directly"
fi

echo "Box net.inotify anti-loop policy regression checks passed"
