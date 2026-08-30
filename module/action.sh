#!/system/bin/sh
MODDIR=${0%/*}
"$MODDIR/bin/reconcile.sh" action
echo '=== Millet Guard diagnostics ==='
"$MODDIR/bin/milletctl" status
echo 'Watchers:'
for f in /data/adb/millet_guard/inotifyd.pid /data/adb/millet_guard/safety.pid; do
  [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f")"
done
echo 'Recent log:'
tail -n 80 /data/adb/millet_guard/module.log 2>/dev/null || true
