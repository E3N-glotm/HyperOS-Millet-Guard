#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/bin/lib.sh"

DOWN_FILE=$RUNDIR/fcm_down_since.epoch
LAST_FILE=$RUNDIR/fcm_recover.epoch
ATTEMPT_FILE=$RUNDIR/fcm_recover.attempts
PATHLOG_FILE=$RUNDIR/fcm_path_fail_log.epoch
BOX_CONFIG=/data/adb/box/sing-box/config.json

ensure_fcm_uid_bypass() {
  # App UIDs are installation-state data and can change after a factory reset.
  # When the tested Box/TProxy chain exists, maintain one narrow FCM-only rule
  # instead of relying on a restored --uid-owner value from an older install.
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -t mangle -S BOX_LOCAL >/dev/null 2>&1 || return 0
  uid=$(pm list packages -U com.google.android.gms 2>/dev/null \
    | awk '$1 == "package:com.google.android.gms" { sub(/^uid:/, "", $2); print $2; exit }')
  case "$uid" in ''|*[!0-9]*) return 0;; esac
  if ! iptables -t mangle -C BOX_LOCAL -p tcp -m owner --uid-owner "$uid" \
      -m tcp --dport 5228:5230 -j RETURN >/dev/null 2>&1; then
    if iptables -t mangle -I BOX_LOCAL 1 -p tcp -m owner --uid-owner "$uid" \
        -m tcp --dport 5228:5230 -j RETURN >/dev/null 2>&1; then
      log_msg "FCM guard: restored Box FCM-only bypass uid=$uid ports=5228:5230"
    fi
  fi
}

fcm_state() {
  line=$(run_timeout dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null \
    | grep -m1 'Is client connected:' || true)
  case "$line" in
    *true*)  echo connected ;;
    *false*) echo disconnected ;;
    *)       echo unknown ;;
  esac
}

configured_fcm_dns() {
  [ -r "$BOX_CONFIG" ] || return 1
  awk -F'"' '
    $2 == "tag" && $4 == "fcm" { want=1; next }
    want && $2 == "server" { print $4; exit }
    want && /}/ { want=0 }
  ' "$BOX_CONFIG" 2>/dev/null
}

resolve_mtalk() {
  # Prefer the resolver used by the tested sing-box FCM DNS rule. Keep public
  # fallbacks so an older/restored Box config does not make diagnostics blind.
  configured=$(configured_fcm_dns 2>/dev/null || true)
  for resolver in "$configured" 61.139.2.69 223.5.5.5 119.29.29.29; do
    [ -n "$resolver" ] || continue
    out=$("$BB" timeout 7 "$BB" nslookup mtalk.google.com "$resolver" 2>/dev/null || true)
    ip=$(printf '%s\n' "$out" | awk '
      /^Name:/ { seen=1; next }
      seen && /^Address [0-9]+: / { print $3; exit }
    ')
    case "$ip" in
      *.*.*.*) printf '%s %s\n' "$resolver" "$ip"; return 0 ;;
    esac
  done
  return 1
}

fcm_path_ready() {
  pair=$(resolve_mtalk) || return 1
  resolver=${pair%% *}
  ip=${pair#* }
  for port in 5228 5229 5230; do
    if "$BB" timeout 6 "$BB" nc -z -w 4 "$ip" "$port" >/dev/null 2>&1; then
      printf '%s %s %s\n' "$resolver" "$ip" "$port"
      return 0
    fi
  done
  return 1
}

rate_limited_path_log() {
  now=$1
  last=$(cat "$PATHLOG_FILE" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ $((now-last)) -ge 900 ] 2>/dev/null; then
    echo "$now" > "$PATHLOG_FILE"
    log_msg "FCM guard: GcmService disconnected but mtalk TCP path unavailable; no GMS restart"
  fi
}

# Keep the port-only Box exception self-healing across Box rule rebuilds and
# clean installs before evaluating the GCM state.
ensure_fcm_uid_bypass

now=$(date +%s)
state=$(fcm_state)
case "$state" in
  connected)
    rm -f "$DOWN_FILE" "$ATTEMPT_FILE" "$PATHLOG_FILE" 2>/dev/null || true
    exit 0
    ;;
  unknown)
    # Fail closed: diagnostics failure must never trigger process intervention.
    exit 0
    ;;
esac

# Explicitly disconnected from GCM/FCM from here on. Keep this scoped to the
# tested Box/sing-box stack rather than becoming a generic network watchdog.
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

# Give Google's own reconnect logic five minutes before intervention. The old
# 10m grace plus 30/60/120m retry schedule could turn one stuck MCS state into
# a multi-hour push outage.
[ $((now-down_since)) -ge 300 ] 2>/dev/null || exit 0

# Distinguish a stuck GMS/MCS client from a genuine FCM path outage. Restarting
# GMS cannot repair an unreachable network and would only waste battery.
path=$(fcm_path_ready 2>/dev/null || true)
if [ -z "$path" ]; then
  rate_limited_path_log "$now"
  exit 0
fi
rm -f "$PATHLOG_FILE" 2>/dev/null || true

attempts=$(cat "$ATTEMPT_FILE" 2>/dev/null)
case "$attempts" in ''|*[!0-9]*) attempts=0;; esac
last=$(cat "$LAST_FILE" 2>/dev/null)
case "$last" in ''|*[!0-9]*) last=0;; esac

# Fast early recovery, progressively reducing churn. Persistent failures are
# capped at one intervention per hour instead of either hammering GMS or
# waiting two hours between attempts.
case "$attempts" in
  0) min_gap=0 ;;
  1) min_gap=300 ;;
  2) min_gap=600 ;;
  3) min_gap=1200 ;;
  4|5) min_gap=1800 ;;
  *) min_gap=3600 ;;
esac
[ $((now-last)) -ge "$min_gap" ] 2>/dev/null || exit 0

resolver=${path%% *}
rest=${path#* }
ip=${rest%% *}
port=${rest##* }
log_msg "FCM guard: outage=$((now-down_since))s path=ok resolver=$resolver endpoint=$ip:$port; restarting gms.persistent pid=$gpid attempt=$((attempts+1))"
echo "$now" > "$LAST_FILE"
echo $((attempts+1)) > "$ATTEMPT_FILE"
kill -TERM "$gpid" 2>/dev/null || exit 0
sleep 20

state2=$(fcm_state)
if [ "$state2" = "connected" ]; then
  rm -f "$DOWN_FILE" "$ATTEMPT_FILE" "$PATHLOG_FILE" 2>/dev/null || true
  newpid=$(pidof com.google.android.gms.persistent 2>/dev/null | awk '{print $1}')
  endpoint=$(run_timeout dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null \
    | grep -m1 'connected=' | sed 's/^[[:space:]]*//' || true)
  log_msg "FCM guard: recovered newpid=${newpid:-unknown} ${endpoint:-endpoint-unavailable}"
else
  log_msg "FCM guard: restart issued but GcmService state=$state2; retry schedule retained"
fi
