#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/dist"
mkdir -p "$OUT"
VERSION=$(awk -F= '$1=="version" {print $2}' "$ROOT/module/module.prop")
ZIP="$OUT/MilletGuard-v${VERSION}.zip"
STAGE="$ROOT/.build-stage.$$"
trap 'rm -rf "$STAGE"' EXIT INT TERM
rm -f "$ZIP"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$ROOT/module/." "$STAGE/"

# Compiled Android arm64 alarmtimer helper is retained as reviewed source +
# fixed SHA256 build payload. Unknown CPU/unsupported kernels fall back to
# ordinary sleep; no native files are created outside the Magisk module.
base64 -d "$ROOT/native/fcm_wake_wait.arm64.b64" > "$STAGE/bin/fcm_wake_wait"
(
  cd "$STAGE/bin"
  printf '%s  %s\n' 'ff143ff6de97949fa1ab211017e0b56d015160558a5938f35f00db3ff4de3221' fcm_wake_wait | sha256sum -c -
)
chmod 0755 "$STAGE/bin/fcm_wake_wait"

# A Windows checkout may expose CRLF even though the Git object is normalized
# to LF. Android /system/bin/sh rejects CRLF scripts, so make the release ZIP
# deterministic and safe regardless of the host checkout policy. The Magisk
# module currently contains text files only.
find "$STAGE" -type f -exec sed -i 's/\r$//' {} +
(
  cd "$STAGE"
  zip -qr "$ZIP" . -x '*.DS_Store'
)
echo "$ZIP"

if [ -f "$ROOT/build-companion.sh" ]; then
  bash "$ROOT/build-companion.sh"
fi
