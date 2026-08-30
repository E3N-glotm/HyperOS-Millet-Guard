#!/system/bin/sh
# Magisk customize script. Keep persistent user configuration outside MODPATH
# so upgrades do not overwrite it.
RUNDIR=/data/adb/millet_guard
CONFIG=$RUNDIR/packages.list
mkdir -p "$RUNDIR"
chmod 700 "$RUNDIR"
if [ ! -f "$CONFIG" ]; then
  cat > "$CONFIG" <<'LIST'
# Millet Guard managed packages, one Android package name per line.
# Blank lines and lines starting with # are ignored.
com.google.android.gms
LIST
  chmod 600 "$CONFIG"
fi
# Migrate the old runtime log/state directory only where useful. Never import
# MILLET_NO_RESTRICT_APP wholesale: it can contain stale entries from v1.x.
OLD=/data/adb/gms_millet_guard
if [ -d "$OLD" ] && [ ! -f "$RUNDIR/migrated_from_v1" ]; then
  [ -f "$OLD/module.log" ] && cp -f "$OLD/module.log" "$RUNDIR/module-v1.log" 2>/dev/null
  touch "$RUNDIR/migrated_from_v1"
fi
ui_print "- Millet Guard configuration: $CONFIG"
ui_print "- Default managed package: com.google.android.gms"
ui_print "- Edit packages.list or use bin/milletctl after installation"
