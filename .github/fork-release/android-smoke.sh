#!/usr/bin/env bash
# Fork only: install the x86_64 APK on a running Android emulator and check
# that the app starts and stays up. Fork Release Check reports this but does
# not block a release on it.
#
#   android-smoke.sh <apk> <output-dir>
set -euo pipefail

APK=$1
OUT=$2
PKG=com.kkrainbow.easytier
mkdir -p "$OUT"

# The nightly APK may be unsigned; Android refuses to install that, so sign a
# copy with a throwaway key. This only affects the test install.
apksigner=$(ls "$ANDROID_HOME"/build-tools/*/apksigner | sort -V | tail -n 1)
if ! "$apksigner" verify "$APK" >/dev/null 2>&1; then
  echo "APK is not signed; signing a test copy."
  keytool -genkeypair -keystore "$OUT/test.jks" -storepass android -keypass android \
    -alias test -keyalg RSA -keysize 2048 -validity 1 -dname CN=smoke >/dev/null 2>&1
  zipalign=$(dirname "$apksigner")/zipalign
  "$zipalign" -f 4 "$APK" "$OUT/aligned.apk"
  "$apksigner" sign --ks "$OUT/test.jks" --ks-pass pass:android --out "$OUT/test.apk" "$OUT/aligned.apk"
  APK=$OUT/test.apk
fi

adb install -r "$APK"
# Pre-grant the VPN consent dialog that would otherwise wait for a tap.
adb shell appops set "$PKG" ACTIVATE_VPN allow || true
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null

sleep 30
pid=$(adb shell pidof "$PKG" | tr -d '\r' || true)
adb exec-out screencap -p > "$OUT/screen.png" || true
adb logcat -d > "$OUT/logcat.txt" || true

if grep -E "FATAL EXCEPTION|Fatal signal|ANR in $PKG" "$OUT/logcat.txt" | grep -q .; then
  grep -E -A20 "FATAL EXCEPTION|Fatal signal|ANR in $PKG" "$OUT/logcat.txt" | head -60
  echo "::error::the app crashed"
  exit 1
fi
[ -n "$pid" ] || { echo "::error::the app is not running 30s after launch"; exit 1; }
echo "app running as pid $pid"
