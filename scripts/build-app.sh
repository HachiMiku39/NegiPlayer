#!/bin/zsh
set -euo pipefail
LMP_PROJECT="${0:A:h:h}"
LMP_WORK="${LMP_WORK_DIR:-${TMPDIR:-/private/tmp}/NegiPlayer-build}"
LMP_CONFIG="${LMP_CONFIGURATION:-release}"
LMP_BUILD_OPTIONS=(-c "$LMP_CONFIG")
# The preview does not require a dSYM; restricted execution can deny dsymutil.
if [[ "$LMP_CONFIG" == "release" && "${NEGI_DEBUG_SYMBOLS:-0}" != "1" ]]; then
  LMP_BUILD_OPTIONS+=(-debug-info-format none)
fi
zsh "$LMP_PROJECT/scripts/swift.sh" build "${LMP_BUILD_OPTIONS[@]}"
LMP_BIN=$(zsh "$LMP_PROJECT/scripts/swift.sh" build "${LMP_BUILD_OPTIONS[@]}" --show-bin-path)
LMP_APP="$LMP_WORK/app-stage/NegiPlayer.app"
mkdir -p "$LMP_WORK/app-stage"
rm -rf "$LMP_APP"
mkdir -p "$LMP_APP/Contents/MacOS" "$LMP_APP/Contents/Resources"
cp "$LMP_BIN/NegiPlayer" "$LMP_APP/Contents/MacOS/NegiPlayer"
cp "$LMP_PROJECT/Resources/Info.plist" "$LMP_APP/Contents/Info.plist"
if [[ -n "${NEGI_BUNDLE_ID:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEGI_BUNDLE_ID" "$LMP_APP/Contents/Info.plist"; fi
cp "$LMP_PROJECT/Resources/PlayerStrings.json" "$LMP_APP/Contents/Resources/PlayerStrings.json"
if [[ -d "$LMP_PROJECT/Resources/Enrichment" ]]; then ditto --norsrc --noextattr "$LMP_PROJECT/Resources/Enrichment" "$LMP_APP/Contents/Resources/Enrichment"; fi
# The original-engine adapter is a research oracle; native SensMe never ships
# or executes it. The optional Gracenote helper remains separate.
rm -f "$LMP_APP/Contents/Resources/Enrichment/sensme_analyze_windows.py"
for LMP_LOCALIZATION in "$LMP_PROJECT"/Resources/*.lproj; do ditto --norsrc --noextattr "$LMP_LOCALIZATION" "$LMP_APP/Contents/Resources/${LMP_LOCALIZATION:t}"; done
if [[ -f "$LMP_PROJECT/Resources/AppIcon.icns" ]]; then cp "$LMP_PROJECT/Resources/AppIcon.icns" "$LMP_APP/Contents/Resources/AppIcon.icns"; fi
rm -f "$LMP_APP/Contents/Resources/VerificationRequest.json"
if [[ "$LMP_CONFIG" == "debug" && -n "${NEGI_VERIFICATION_FIXTURES:-}" && -n "${NEGI_VERIFICATION_REPORT:-}" && -n "${LMP_DATA_DIR:-}" ]]; then
  python3 - "$LMP_APP/Contents/Resources/VerificationRequest.json" <<'PY'
import json, os, sys
with open(sys.argv[1], 'w') as f:
    json.dump(dict(fixtures=os.environ['NEGI_VERIFICATION_FIXTURES'], report=os.environ['NEGI_VERIFICATION_REPORT'], dataDirectory=os.environ['LMP_DATA_DIR'], realSamples=os.environ.get('NEGI_REAL_SAMPLES'), realReport=os.environ.get('NEGI_REAL_REPORT')),f)
PY
fi
# iCloud/Finder metadata can prevent ad-hoc signing. Strip only these metadata attributes on our generated bundle.
xattr -dr com.apple.FinderInfo "$LMP_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$LMP_APP" 2>/dev/null || true
if [[ "${LMP_SANDBOX:-0}" == "1" ]]; then
  codesign --force --sign - --entitlements "$LMP_PROJECT/Resources/NegiPlayer.entitlements" "$LMP_APP"
else
  codesign --force --sign - "$LMP_APP"
fi
codesign --verify --strict "$LMP_APP"
mkdir -p "$LMP_PROJECT/dist"
rm -rf "$LMP_PROJECT/dist/NegiPlayer.app"
ditto --norsrc --noextattr "$LMP_APP" "$LMP_PROJECT/dist/NegiPlayer.app"
# The signed staging copy remains outside an iCloud-synchronised project when LMP_WORK_DIR is /tmp.
print "Built: $LMP_PROJECT/dist/NegiPlayer.app"
print "Verified staging bundle: $LMP_APP"
