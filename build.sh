#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/dist"
mkdir -p "$OUT"
VERSION=$(awk -F= '$1=="version" {print $2}' "$ROOT/module/module.prop")
ZIP="$OUT/MilletGuard-v${VERSION}.zip"
rm -f "$ZIP"
(
  cd "$ROOT/module"
  zip -qr "$ZIP" . -x '*.DS_Store'
)
echo "$ZIP"
