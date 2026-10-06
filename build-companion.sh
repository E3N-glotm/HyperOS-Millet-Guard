#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/dist"
APP_VERSION=$(awk -F"'" '/versionName/ {print $2}' "$ROOT/companion-app/app/build.gradle")
APP_APK="$OUT/WeChat-FCM-Refresh-v${APP_VERSION}.apk"
APP_ZIP="$OUT/WeChat-FCM-Refresh-v${APP_VERSION}-apk.zip"

sh "$ROOT/companion-app/unpack-sources.sh"

if [ -n "${ANDROID_HOME:-}" ] && [ ! -f "$ANDROID_HOME/platforms/android-35/android.jar" ]; then
  SDKMANAGER=$(find "$ANDROID_HOME/cmdline-tools" -type f -name sdkmanager 2>/dev/null | sort -V | tail -n1)
  [ -n "$SDKMANAGER" ] && yes | "$SDKMANAGER" "platforms;android-35" "build-tools;35.0.0" >/dev/null
fi

GRADLE_BIN=$(command -v gradle || true)
if [ -z "$GRADLE_BIN" ]; then
  GRADLE_HOME="/tmp/gradle-8.9"
  if [ ! -x "$GRADLE_HOME/bin/gradle" ]; then
    curl -fsSL https://services.gradle.org/distributions/gradle-8.9-bin.zip -o /tmp/gradle-8.9-bin.zip
    rm -rf "$GRADLE_HOME"
    unzip -q /tmp/gradle-8.9-bin.zip -d /tmp
  fi
  GRADLE_BIN="$GRADLE_HOME/bin/gradle"
fi

(cd "$ROOT/companion-app" && "$GRADLE_BIN" :app:assembleRelease --stacktrace)
UNSIGNED="$ROOT/companion-app/app/build/outputs/apk/release/app-release-unsigned.apk"

curl -fsSL https://raw.githubusercontent.com/aosp-mirror/platform_build/master/target/product/security/testkey.x509.pem -o /tmp/testkey.x509.pem
curl -fsSL https://raw.githubusercontent.com/aosp-mirror/platform_build/master/target/product/security/testkey.pk8 -o /tmp/testkey.pk8
APKSIGNER=$(find "${ANDROID_HOME:-/opt/android-sdk}" -type f -name apksigner 2>/dev/null | sort -V | tail -n1)
[ -x "$APKSIGNER" ] || { echo "apksigner not found" >&2; exit 1; }
"$APKSIGNER" sign --key /tmp/testkey.pk8 --cert /tmp/testkey.x509.pem --out "$APP_APK" "$UNSIGNED"
"$APKSIGNER" verify --verbose "$APP_APK"
sha256sum "$APP_APK" > "$APP_APK.sha256"
rm -f "$APP_ZIP"
(cd "$OUT" && zip -q "$(basename "$APP_ZIP")" "$(basename "$APP_APK")" "$(basename "$APP_APK.sha256")")
echo "$APP_APK"
