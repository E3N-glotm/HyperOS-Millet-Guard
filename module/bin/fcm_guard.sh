#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/bin/lib.sh"

DOWN_FILE=$RUNDIR/fcm_down_since.epoch
LAST_FILE=$RUNDIR/fcm_recover.epoch
ATTEMPT_FILE=$RUNDIR/fcm_recover.attempts
PATHLOG_FILE=$RUNDIR/fcm_path_fail_log.epoch
DNSLOG_FILE=$RUNDIR/fcm_dns_fail_log.epoch
DNSFAIL_FILE=$RUNDIR/fcm_dns_fail.epoch
DNSFLUSH_FILE=$RUNDIR/fcm_dns_flush.epoch
BYPASS_UID_FILE=$RUNDIR/fcm_bypass.uid
LOCK=$RUNDIR/fcm_guard.lock
LOCK_OWNER=$LOCK/owner
BOX_CONFIG=/data/adb/box/sing-box/config.json

proc_start_ticks() {
  pid=$1
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  stat_line=
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  stat_tail=${stat_line##*) }
  [ "$stat_tail" != "$stat_line" ] || return 1
  set -- $stat_tail
  [ "$#" -ge 20 ] || return 1
  shift 19
  case "$1" in ''|*[!0-9]*) return 1;; esac
  printf '%s\n' "$1"
}

guard_lock_owner_alive() {
  [ -r "$LOCK_OWNER" ] || return 1
  read -r owner_pid owner_start < "$LOCK_OWNER" 2>/dev/null || return 1
  case "$owner_pid:$owner_start" in ''|*[!0-9:]*|:*|*:) return 1;; esac
  current_start=$(proc_start_ticks "$owner_pid") || return 1
  [ "$current_start" = "$owner_start" ]
}

guard_lock_age() {
  lock_mtime=$("$BB" stat -c %Y "$LOCK" 2>/dev/null)
  lock_now=$(date +%s)
  case "$lock_mtime:$lock_now" in
    *[!0-9:]*|:*|*:) echo 0;;
    *) echo $((lock_now-lock_mtime));;
  esac
}

acquire_guard_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    start=$(proc_start_ticks $$)
    [ -n "$start" ] || start=0
    printf '%s %s\n' "$$" "$start" > "$LOCK_OWNER"
    return 0
  fi
  guard_lock_owner_alive && return 1
  age=$(guard_lock_age)
  [ "$age" -ge 30 ] 2>/dev/null || return 1
  log_msg "FCM guard: recovering stale single-instance lock age=${age}s"
  rm -rf "$LOCK" 2>/dev/null || return 1
  if mkdir "$LOCK" 2>/dev/null; then
    start=$(proc_start_ticks $$)
    [ -n "$start" ] || start=0
    printf '%s %s\n' "$$" "$start" > "$LOCK_OWNER"
    return 0
  fi
  return 1
}

release_guard_lock() {
  [ -r "$LOCK_OWNER" ] || return 0
  read -r owner_pid owner_start < "$LOCK_OWNER" 2>/dev/null || return 0
  [ "$owner_pid" = "$$" ] || return 0
  rm -rf "$LOCK" 2>/dev/null || true
}

fcm_rule_count() {
  rule_uid=$1
  iptables -t mangle -S BOX_LOCAL 2>/dev/null | awk -v uid="$rule_uid" '
    $1 == "-A" && $2 == "BOX_LOCAL" {
      owner=0; port=0; ret=0
      for (i=1; i<=NF; i++) {
        if ($i == "--uid-owner" && $(i+1) == uid) owner=1
        if ($i == "--dport" && $(i+1) == "5228:5230") port=1
        if ($i == "-j" && $(i+1) == "RETURN") ret=1
      }
      if (owner && port && ret) count++
    }
    END { print count+0 }
  '
}

delete_fcm_rules_for_uid() {
  delete_uid=$1
  delete_count=$(fcm_rule_count "$delete_uid")
  case "$delete_count" in ''|*[!0-9]*) delete_count=0;; esac
  while [ "$delete_count" -gt 0 ] 2>/dev/null; do
    iptables -t mangle -D BOX_LOCAL -p tcp -m owner --uid-owner "$delete_uid" \
      -m tcp --dport 5228:5230 -j RETURN >/dev/null 2>&1 || break
    delete_count=$((delete_count-1))
  done
}

ensure_fcm_uid_bypass() {
  # App UIDs are installation-state data and can change after a factory reset.
  # When the tested Box/TProxy chain exists, maintain one narrow FCM-only rule
  # instead of relying on a restored --uid-owner value from an older install.
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -t mangle -S BOX_LOCAL >/dev/null 2>&1 || return 0
  gms_uid=$(pm list packages -U com.google.android.gms 2>/dev/null \
    | awk '$1 == "package:com.google.android.gms" { sub(/^uid:/, "", $2); print $2; exit }')
  case "$gms_uid" in ''|*[!0-9]*) return 0;; esac

  old_uid=$(cat "$BYPASS_UID_FILE" 2>/dev/null)
  case "$old_uid" in ''|*[!0-9]*) old_uid=;; esac
  if [ -n "$old_uid" ] && [ "$old_uid" != "$gms_uid" ]; then
    delete_fcm_rules_for_uid "$old_uid"
    log_msg "FCM guard: removed stale managed Box FCM bypass old_uid=$old_uid"
  fi

  count=$(fcm_rule_count "$gms_uid")
  case "$count" in ''|*[!0-9]*) count=0;; esac
  if [ "$count" -ne 1 ] 2>/dev/null; then
    [ "$count" -gt 0 ] 2>/dev/null && delete_fcm_rules_for_uid "$gms_uid"
    if iptables -t mangle -I BOX_LOCAL 1 -p tcp -m owner --uid-owner "$gms_uid" \
        -m tcp --dport 5228:5230 -j RETURN >/dev/null 2>&1; then
      log_msg "FCM guard: normalized Box FCM-only bypass uid=$gms_uid ports=5228:5230 previous_count=$count"
    fi
  fi
  printf '%s\n' "$gms_uid" > "$BYPASS_UID_FILE"
  chmod 600 "$BYPASS_UID_FILE" 2>/dev/null || true
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

android_resolve_mtalk() {
  # Deliberately use Android's libc/netd resolver path instead of direct
  # nslookup. The latter can succeed against a configured upstream while GMS
  # itself is still receiving UNKNOWN_HOST through Android's resolver chain.
  out=$(run_timeout /system/bin/ping -c 1 -W 1 mtalk.google.com 2>&1 || true)
  ip=$(printf '%s\n' "$out" | awk '
    /PING[[:space:]]+mtalk[.]google[.]com/ {
      if (match($0, /\([0-9][0-9.]*\)/)) {
        value=substr($0, RSTART+1, RLENGTH-2)
        if (split(value, octets, ".") == 4) { print value; exit }
      }
    }
  ')
  case "$ip" in *.*.*.*) printf '%s\n' "$ip"; return 0;; esac
  return 1
}

recent_gms_unknown_host_epoch() {
  # gtalk_connection packs connection_error in bits 8..15; Android's event
  # definition assigns value 3 to UNKNOWN_HOST. Only recent evidence blocks a
  # process restart, so an old historical event cannot suppress recovery.
  line=$(run_timeout logcat -b events -d -v epoch -t 400 2>/dev/null \
    | grep 'gtalk_connection' | tail -n 1 || true)
  [ -n "$line" ] || return 1
  pair=$(printf '%s\n' "$line" | awk '
    {
      ts=$1; sub(/[.].*$/, "", ts)
      if (ts !~ /^[0-9]+$/) next
      for (i=NF; i>=1; i--) {
        v=$i; gsub(/[^0-9]/, "", v)
        if (v ~ /^[0-9]+$/) { print ts " " v; exit }
      }
    }
  ')
  [ -n "$pair" ] || return 1
  event_epoch=${pair%% *}
  status=${pair#* }
  case "$event_epoch:$status" in *[!0-9:]*|:*|*:) return 1;; esac
  err=$(( (status / 256) % 256 ))
  [ "$err" -eq 3 ] 2>/dev/null || return 1
  event_now=$(date +%s)
  event_age=$((event_now-event_epoch))
  [ "$event_age" -ge 0 ] 2>/dev/null || return 1
  [ "$event_age" -le 900 ] 2>/dev/null || return 1
  printf '%s\n' "$event_epoch"
}

remember_dns_failure() {
  stamp=$1
  case "$stamp" in ''|*[!0-9]*) return 0;; esac
  old=$(cat "$DNSFAIL_FILE" 2>/dev/null)
  case "$old" in ''|*[!0-9]*) old=0;; esac
  [ "$stamp" -gt "$old" ] 2>/dev/null && printf '%s\n' "$stamp" > "$DNSFAIL_FILE"
}

dns_netids() {
  run_timeout dumpsys dnsresolver 2>/dev/null | awk '
    /NetId:/ {
      for (i=1; i<=NF; i++) {
        if ($i == "NetId:" && $(i+1) ~ /^[0-9]+$/ && !seen[$(i+1)]++) print $(i+1)
      }
    }
  '
}

flush_android_dns() {
  flush_now=$1
  last_flush=$(cat "$DNSFLUSH_FILE" 2>/dev/null)
  case "$last_flush" in ''|*[!0-9]*) last_flush=0;; esac
  [ $((flush_now-last_flush)) -ge 300 ] 2>/dev/null || return 0
  printf '%s\n' "$flush_now" > "$DNSFLUSH_FILE"

  flushed=0
  for netid in $(dns_netids); do
    if command -v ndc >/dev/null 2>&1 \
        && "$BB" timeout 5 ndc resolver flushnet "$netid" >/dev/null 2>&1; then
      flushed=$((flushed+1))
      continue
    fi
    if "$BB" timeout 5 cmd netd resolver flushnet "$netid" >/dev/null 2>&1; then
      flushed=$((flushed+1))
    fi
  done
  if [ "$flushed" -gt 0 ] 2>/dev/null; then
    log_msg "FCM guard: flushed Android DNS cache networks=$flushed"
  else
    log_msg "FCM guard: Android DNS cache flush unsupported/no active resolver netId; restart remains blocked while DNS is unhealthy"
  fi
}

rate_limited_dns_log() {
  dns_now=$1
  shift
  last=$(cat "$DNSLOG_FILE" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ $((dns_now-last)) -ge 900 ] 2>/dev/null; then
    printf '%s\n' "$dns_now" > "$DNSLOG_FILE"
    log_msg "FCM guard: $*"
  fi
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

# Polling and the event worker can wake at the same time. Serialize the whole
# guard so they cannot duplicate firewall rules or race restart accounting.
acquire_guard_lock || exit 0
trap 'release_guard_lock' EXIT HUP INT TERM

# Keep the port-only Box exception self-healing across Box rule rebuilds and
# clean installs before evaluating the GCM state.
ensure_fcm_uid_bypass

now=$(date +%s)
state=$(fcm_state)
case "$state" in
  connected)
    rm -f "$DOWN_FILE" "$ATTEMPT_FILE" "$PATHLOG_FILE" "$DNSLOG_FILE" "$DNSFAIL_FILE" 2>/dev/null || true
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
outage=$((now-down_since))

# DNS failures are actionable earlier than a process restart. A recent
# UNKNOWN_HOST emitted by GMS itself is authoritative evidence that killing
# gms.persistent is the wrong layer to repair. Refresh resolver caches at a
# bounded rate, then leave Google's reconnect logic intact.
if [ "$outage" -ge 60 ] 2>/dev/null; then
  unknown_epoch=$(recent_gms_unknown_host_epoch 2>/dev/null || true)
  if [ -n "$unknown_epoch" ]; then
    unknown_age=$((now-unknown_epoch))
    if [ "$unknown_age" -lt 600 ] 2>/dev/null; then
      remember_dns_failure "$unknown_epoch"
      flush_android_dns "$now"
      rate_limited_dns_log "$now" "GMS reported UNKNOWN_HOST ${unknown_age}s ago; DNS remediation only, no GMS restart"
      exit 0
    fi
  fi

  android_ip=$(android_resolve_mtalk 2>/dev/null || true)
  if [ -z "$android_ip" ]; then
    remember_dns_failure "$now"
    flush_android_dns "$now"
    rate_limited_dns_log "$now" "Android resolver cannot resolve mtalk.google.com; DNS remediation only, no GMS restart"
    exit 0
  fi

  last_dns_fail=$(cat "$DNSFAIL_FILE" 2>/dev/null)
  case "$last_dns_fail" in ''|*[!0-9]*) last_dns_fail=0;; esac
  if [ "$last_dns_fail" -gt 0 ] 2>/dev/null && [ $((now-last_dns_fail)) -lt 300 ] 2>/dev/null; then
    rate_limited_dns_log "$now" "Android resolver recovered mtalk=$android_ip but is inside 300s stability grace; no GMS restart"
    exit 0
  fi
fi

# Give Google's own reconnect logic five minutes before intervention. The old
# 10m grace plus 30/60/120m retry schedule could turn one stuck MCS state into
# a multi-hour push outage.
[ "$outage" -ge 300 ] 2>/dev/null || exit 0

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
android_ip=$(android_resolve_mtalk 2>/dev/null || true)
[ -n "$android_ip" ] || exit 0
log_msg "FCM guard: outage=${outage}s direct_path=ok resolver=$resolver endpoint=$ip:$port android_resolver=$android_ip; restarting gms.persistent pid=$gpid attempt=$((attempts+1))"
echo "$now" > "$LAST_FILE"
echo $((attempts+1)) > "$ATTEMPT_FILE"
kill -TERM "$gpid" 2>/dev/null || exit 0
sleep 20

state2=$(fcm_state)
if [ "$state2" = "connected" ]; then
  rm -f "$DOWN_FILE" "$ATTEMPT_FILE" "$PATHLOG_FILE" "$DNSLOG_FILE" "$DNSFAIL_FILE" 2>/dev/null || true
  newpid=$(pidof com.google.android.gms.persistent 2>/dev/null | awk '{print $1}')
  endpoint=$(run_timeout dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null \
    | grep -m1 'connected=' | sed 's/^[[:space:]]*//' || true)
  log_msg "FCM guard: recovered newpid=${newpid:-unknown} ${endpoint:-endpoint-unavailable}"
else
  log_msg "FCM guard: restart issued but GcmService state=$state2; retry schedule retained"
fi
