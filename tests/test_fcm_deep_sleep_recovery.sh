#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GUARD="$ROOT/module/bin/fcm_guard.sh"
SERVICE="$ROOT/module/service.sh"
BUILD="$ROOT/build.sh"
FAIL() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'CLOCK_BOOTTIME_ALARM' "$ROOT/native/fcm_wake_wait.c" || FAIL "no alarmtimer"
grep -Fq 'timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC)' "$ROOT/native/fcm_wake_wait.c" ||
  FAIL "not using a kernel wakeup-capable timer"
grep -Fq 'timerfd_settime(fd, 0, &t, NULL)' "$ROOT/native/fcm_wake_wait.c" ||
  FAIL "missing one-shot timer"
grep -q 'wake_helper.*fcm_wake_wait' "$SERVICE" || FAIL "service fails to arm alarmtimer"
grep -q 'wake_supported=0' "$SERVICE" || FAIL "missing fail-closed fallback"
grep -q 'delay=600' "$SERVICE" || FAIL "healthy wake interval missing"
grep -q 'delay=180' "$SERVICE" || FAIL "outage wake interval missing"
grep -q 'sleep 120' "$SERVICE" || FAIL "unsupported devices need old fallback"
grep -q '! -name fcm_wake_wait' "$BUILD" || FAIL "binary must not be normalized"
grep -Fq 'sha256sum -c -' "$BUILD" || FAIL "native binary not hash checked"

# Extract pure watchdog decisions without executing fcm_guard.sh's Magisk
# environment or changing Android service state.
functions=$(sed -n '/^fcm_mcs_socket_ready() {/,/^}/p' "$GUARD")
functions="$functions
$(sed -n '/^fcm_default_net_validated() {/,/^}/p' "$GUARD")"
[ -n "$functions" ] || FAIL "missing functions"
eval "$functions"
gms_uid_for_probe() { echo 10139; }
ss() { :; } # allows command -v ss to succeed on minimal CI hosts
run_timeout() {
  if [ "$1" = ss ]; then printf '%s\n' "$SS_RESULT"; return 0; fi
  if [ "$1" = dumpsys ] && [ "$2" = connectivity ]; then
    printf '%s\n' "$NETWORK_RESULT"; return 0
  fi
  return 1
}

# Use the Android kernel ss -Htnpe tuple format with a GMS-owned socket.
SS_RESULT='0 0 [::ffff:10.0.0.2]:44580 [::ffff:172.217.78.188]:443 users:(("gle.android.gms",pid=7891,fd=146)) uid:10139 ino:260735 sk:2384'
fcm_mcs_socket_ready 'connected=alt2-mtalk.google.com/172.217.78.188,port=443' ||
  FAIL "GMS-owned alternate MCS TCP443 not accepted"
if fcm_mcs_socket_ready 'connected=alt2-mtalk.google.com/172.217.78.187,port=443'; then
  FAIL "mismatched IP accepted"
fi
if fcm_mcs_socket_ready 'connected=example.com/172.217.78.188,port=443'; then
  FAIL "arbitrary 443 allowed"
fi
SS_RESULT='0 0 [::ffff:10.0.0.2]:44580 [::ffff:172.217.78.188]:443 users:(("gle.android.gms",pid=7891,fd=146)) uid:10200 ino:260735 sk:2384'
if fcm_mcs_socket_ready 'connected=alt2-mtalk.google.com/172.217.78.188,port=443'; then
  FAIL "other UID allowed"
fi
SS_RESULT='0 0 [::ffff:10.0.0.2]:44580 [::ffff:172.217.78.188]:443 users:(("gle.android.gms",pid=7891,fd=146)) uid:10139 ino:260735 sk:2384'
if fcm_mcs_socket_ready 'connected=alt2-mtalk.google.com/172.217.78.188,port=444'; then
  FAIL "non-MCS TCP port allowed"
fi

NETWORK_RESULT='Active default network: 299
NetworkAgentInfo{network{299} Score(EVER_VALIDATED) nc{[ Transports: WIFI Capabilities: INTERNET&TRUSTED&VALIDATED LinkUpBandwidth>=200Kbps]}'
fcm_default_net_validated || FAIL "valid network not recognized"
NETWORK_RESULT='Active default network: 299
NetworkAgentInfo{network{299} Score(EVER_VALIDATED) nc{[ Transports: WIFI Capabilities: INTERNET&TRUSTED LinkUpBandwidth>=200Kbps]}'
if fcm_default_net_validated; then FAIL "unvalidated network allowed"; fi
NETWORK_RESULT='Active default network: 299
NetworkAgentInfo{network{300} Score(IS_VALIDATED) nc{[ Transports: WIFI Capabilities: INTERNET&TRUSTED&VALIDATED LinkUpBandwidth>=200Kbps]}'
if fcm_default_net_validated; then FAIL "wrong NetId allowed"; fi

grep -Fq '[ "$outage" -ge 900 ]' "$GUARD" || FAIL "DNS escape budget missing"
grep -Fq '[ "$outage" -ge 1800 ]' "$GUARD" || FAIL "last-resort delay missing"
grep -Fq '[ "$verified_mcs" = 0 ] && [ "$attempts" -ge 2 ]' "$GUARD" ||
  FAIL "unproven-path GMS restarts must be capped"
grep -Fq 'actual_uid=$(awk' "$GUARD" || FAIL "GMS process UID verification missing"
grep -Fq 'fcm_mcs_socket_ready "$endpoint"' "$GUARD" ||
  FAIL "post-recovery must validate actual GMS socket"
echo "FCM deep-suspend and bounded auto-recovery regression: PASS"
