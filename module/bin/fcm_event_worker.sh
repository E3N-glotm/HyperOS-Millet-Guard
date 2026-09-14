#!/system/bin/sh
MODDIR=${0%/*}/..

# `--regex` is present on the validated Android 16 logcat. On older builds,
# exit cleanly and let the independent two-minute fallback do the work instead
# of repeatedly spawning an unsupported logcat command.
logcat --help 2>&1 | grep -q -- '--regex' || exit 0

# One merged logcat stream serves two independent event-driven paths:
# 1) existing GMS AlarmManager wakeups -> FCM health check;
# 2) HyperOS ActivityManager SwipeUpClean force-stop -> opt-in package unstop.
# The second path deliberately matches only the explicit SwipeUpClean reason.
# App-info / shell / policy force-stops are therefore left untouched.
#
# HyperOS logs the ActivityManager/ProcessSceneCleaner SwipeUpClean records in
# the system buffer on the validated device, while Whetstone alarm deliveries
# are visible in main. Listen to both buffers so neither event path is lost.
while true; do
  logcat -b main -b system -v brief -T 1 \
    --regex='sourcePkg=com.google.android.gms|Force stopping .*: SwipeUpClean' \
    -s whetstone.activity:I ActivityManager:I '*:S' 2>/dev/null \
  | while IFS= read -r _line; do
      case "$_line" in
        *"Force stopping "*": SwipeUpClean"*)
          pkg=$(printf '%s\n' "$_line" | sed -n 's/.*Force stopping \([^ ]*\) .*: SwipeUpClean.*/\1/p')
          [ -n "$pkg" ] && /system/bin/sh "$MODDIR/bin/swipe_unstop.sh" "$pkg" >/dev/null 2>&1 || true
          ;;
        *"sourcePkg=com.google.android.gms"*)
          /system/bin/sh "$MODDIR/bin/fcm_guard.sh" alarm-event >/dev/null 2>&1 || true
          ;;
      esac
    done
  # If logcat is restarted/rotated, retry quietly instead of hot-looping.
  sleep 5
done
