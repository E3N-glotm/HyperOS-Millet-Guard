#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HANDLER="$ROOT/extras/box-for-root/net.inotify"
INSTALL="$ROOT/extras/box-for-root/install.sh"
VERIFY="$ROOT/extras/box-for-root/verify.sh"
ROLLBACK="$ROOT/extras/box-for-root/rollback.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in "$HANDLER" "$INSTALL" "$VERIFY" "$ROLLBACK"; do
  sh -n "$file" || fail "shell syntax: $file"
done

grep -q 'proc_start_ticks' "$HANDLER" || fail "PID/start-time stale lock validation missing"
grep -q 'recovering stale network-context lock' "$HANDLER" || fail "stale lock recovery missing"
grep -q 'restart_cooldown=15' "$HANDLER" || fail "restart cooldown missing"
grep -q 'acquire_net_lock || exit 0' "$HANDLER" || fail "network handler is not serialized"

main_lock=$(grep -n 'acquire_net_lock || exit 0' "$HANDLER" | tail -n1 | cut -d: -f1)
main_rules=$(grep -n '^  rules_add$' "$HANDLER" | tail -n1 | cut -d: -f1)
state_commit=$(grep -n 'atomic_write "$state_file" "$stable_signature"' "$HANDLER" | tail -n1 | cut -d: -f1)
restart=$(grep -n '^"$service_path" restart' "$HANDLER" | tail -n1 | cut -d: -f1)

[ "$main_lock" -lt "$main_rules" ] || fail "lock must precede rules_add"
[ "$state_commit" -lt "$restart" ] || fail "signature commit must precede Box restart"

if grep -Eq 'ip[[:space:]]+(route|rule)[[:space:]]+(add|del|flush|replace)' "$HANDLER"; then
  fail "handler must not mutate routes/rules directly"
fi

backup_line=$(grep -n 'cp -p "$TARGET" "$BACKUP/net.inotify"' "$INSTALL" | cut -d: -f1)
install_line=$(grep -n '^mv "$TMP" "$TARGET"' "$INSTALL" | cut -d: -f1)
[ "$backup_line" -lt "$install_line" ] || fail "installer must back up before replacing handler"

grep -q 'install rolled back' "$INSTALL" || fail "automatic install rollback missing"
grep -q 'PRECHECK PASS' "$INSTALL" || fail "read-only installer precheck missing"
grep -q 'No files, processes, iptables rules, or services were modified' "$INSTALL" || fail "precheck non-mutation contract missing"
grep -q 'net-context-compat.last-backup' "$ROLLBACK" || fail "latest-backup rollback support missing"
grep -q 'net.monitor.pid' "$VERIFY" || fail "monitor singleton must be verified by pidfile"

echo "Box compatibility branch regression: PASS"

