#!/usr/bin/env sh
set -eu
OUT="companion-app/app/src/main/java/com/e3n/wechatfcmrefresh"
mkdir -p "$OUT"
cat companion-app/src-packed/main.part00 companion-app/src-packed/main.part01 companion-app/src-packed/main.part02 companion-app/src-packed/main.part03 |
  base64 -d | gzip -d > "$OUT/MainActivity.java"
base64 -d companion-app/src-packed/roothelper.gz.b64 | gzip -d > "$OUT/RootOps.java"
