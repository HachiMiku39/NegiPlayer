#!/bin/bash
set -euo pipefail
task_temp="$(mktemp -d)"
task_pid=""
cleanup() { test -z "$task_pid" || kill "$task_pid" 2>/dev/null || true; rm -rf "$task_temp"; }
trap cleanup EXIT
dotnet run --project cross/NegiPlayer.Conformance -c Release -- --serve --address 10.0.2.2 --ready "$task_temp/ready.json" --seconds 240 > "$task_temp/host.log" 2>&1 &
task_pid="$!"
for i in {1..200}; do test -f "$task_temp/ready.json" && break; sleep 0.1; done
test -f "$task_temp/ready.json"
task_address="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["baseURL"])' "$task_temp/ready.json")"
task_fp="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$task_temp/ready.json")"
task_code="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["code"])' "$task_temp/ready.json")"
adb install -r ci-artifacts/NegiPlayer-0.5.0-Android-development.apk
adb shell am start -n com.negiplayer.mobile/.MainActivity --ez negi_conformance true --es negi_address "$task_address" --es negi_fingerprint "$task_fp" --es negi_code "$task_code" >/dev/null
for i in {1..120}; do
  if test ! -f ci-artifacts/android-playing.png && adb shell run-as com.negiplayer.mobile test -f files/presentation-ready; then
    adb exec-out screencap -p > ci-artifacts/android-playing.png
  fi
  if adb shell run-as com.negiplayer.mobile cat files/conformance-result.json > "$task_temp/result.json" 2>/dev/null; then break; fi
  sleep 0.5
done
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("passed") and r.get("audioTrackVirtualOutput"), r' "$task_temp/result.json"
cp "$task_temp/result.json" ci-artifacts/android-emulator-conformance.json
adb shell am force-stop com.negiplayer.mobile
echo 'PASS: Android read-only LAN, source PCM, artwork/LRC, EQ and virtual AudioTrack output.'
