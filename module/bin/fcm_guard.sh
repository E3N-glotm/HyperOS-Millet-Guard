#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/bin/lib.sh"

DOWN_FILE=$RUNDIR/fcm_down_since.epoch
LAST_FILE=$RUNDIR/fcm_recover.epoch
ATTEMPT_FILE=$RUNDIR/fcm_recover.attempts

fcm_state() {
  line=$(run_timeout dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null \
    | grep -m1 'Is client connected:' || true)
  case "$line" in
    *true*)  echo connected ;;
    *false*) echo disconnected ;;
    *)       echo unknown ;;
  esac
}

fcm_dns_ready() {
  # Send a real mtalk DNS query through Box's DNS interception path. The
  # sing-box mtalk rule can route it to a dedicated local/platform resolver.
  # This is only a readiness probe; it does not modify DNS configuration.
  if [ -x /system/xbin/nslookup ]; then
    "$BB" timeout 8 /system/xbin/nslookup mtalk.google.com 223.5.5.5 2>/dev/null
  else
    "$BB" timeout 8 "$BB" nslookup mtalk.google.com 223.5.5.5 2>/dev/null
  fi | grep -Eq '^Address [0-9]+: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

now=$(date +%s)
state=$(fcm_state)
case "$state" in
  connected)
    rm -f "$DOWN_FILE" "$ATTEMPT_FILE" 2>/dev/null || true
    exit 0
    ;;
  unknown)
    # Fail closed for process intervention: never restart GMS merely because
    # diagnostics are unavailable or timed out.
    exit 0
    ;;
esac

# Explicitly disconnected from GCM/FCM from here on. The recovery path is
# intentionally conditional on sing-box so Millet Guard never becomes a
# generic network watchdog on devices that do not use the tested Box setup.
gpid=$(pidof com.google.android.gms.persistent 2>/dev/null | awk '{print $1}')
spid=$(pidof sing-box 2>/dev/null | awk '{print $1}')
[ -n "$gpid" ] && [ -n "$spid" ] || exit 0

if [ ! -f "$DOWN_FILE" ]; then
  echo "$now" > "$DOWN_FILE"
  log_msg "FCM guard: GcmService disconnected; starting outage timer"
  exit 0
fi

down_since=$(cat "$DOWN_FILE" 2>/dev/null)
case "$down_since" in ''|*[!0-9]*) down_since=$now;; esac
# Let Google's own reconnect logic work first. Intervene only after 10 minutes.
[ $((now-down_since)) -ge 600 ] 2>/dev/null || exit 0

# Do not churn GMS while the mtalk resolver/network path is really unavailable.
if ! fcm_dns_ready; then
  log_msg "FCM guard: GcmService disconnected but mtalk DNS unavailable; no GMS restart"
  exit 0
fi

attempts=$(cat "$ATTEMPT_FILE" 2>/dev/null)
case "$attempts" in ''|*[!0-9]*) attempts=0;; esac
last=$(cat "$LAST_FILE" 2>/dev/null)
case "$last" in ''|*[!0-9]*) last=0;; esac

# Exponential spacing after a failed intervention: 30m -> 60m -> 120m cap.
case "$attempts" in
  0) min_gap=0 ;;
  1) min_gap=1800 ;;
  2) min_gap=3600 ;;
  *) min_gap=7200 ;;
esac
[ $((now-last)) -ge "$min_gap" ] 2>/dev/null || exit 0

log_msg "FCM guard: outage=$((now-down_since))s DNS=ok; restarting gms.persistent pid=$gpid attempt=$((attempts+1))"
echo "$now" > "$LAST_FILE"
echo $((attempts+1)) > "$ATTEMPT_FILE"
kill -TERM "$gpid" 2>/dev/null || exit 0
sleep 20

state2=$(fcm_state)
if [ "$state2" = "connected" ]; then
  rm -f "$DOWN_FILE" "$ATTEMPT_FILE" 2>/dev/null || true
  newpid=$(pidof com.google.android.gms.persistent 2>/dev/null | awk '{print $1}')
  endpoint=$(run_timeout dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null \
    | grep -m1 'connected=' | sed 's/^[[:space:]]*//' || true)
  log_msg "FCM guard: recovered newpid=${newpid:-unknown} ${endpoint:-endpoint-unavailable}"
else
  log_msg "FCM guard: restart issued but GcmService state=$state2; backoff retained"
fi
